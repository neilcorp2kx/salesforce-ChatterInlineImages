# Chatter Inline Images

> **Paste screenshots directly into Chatter posts and have them render inline — from a flow screen, quick action, or anywhere else in Lightning Experience.**

Solves [IdeaExchange idea: "Enable pasting images in Chatter for Lightning Experience"](https://ideas.salesforce.com/s/idea/a0B8W00000PFdoSUAT/enable-pasting-images-in-chatter-for-lightning-experience).

## What it does

- **Paste an image** into a rich text editor anywhere in Lightning Experience → it uploads as a real Salesforce File
- **Post it to the Chatter feed** on any record → the image **renders inline** in the native feed, not as a "Click link for image" text
- Works from **Screen Flows**, which means you can drop it behind a **Quick Action** on any object
- Supports **@mentions** with real `MentionSegment` (bell notifications and everything)
- Respects **post visibility** (`Internal Users Only` / `All with Access`)

## Why this is hard (and why the workarounds fail)

If you've tried to build this yourself, you've probably hit one of these dead ends:

### Dead end 1: `FeedItem.Body` is a plain textarea

You can't just drop `<img>` tags into a `FeedItem.Body` and have them render. It's a plain text field. Any HTML you put there gets stripped. This is why hand-rolled flows end up with `"Click link for image: https://..."` text instead of rendered images.

### Dead end 2: Salesforce's `lightning-input-rich-text` intercepts pasted images and uploads them as legacy Rich Text Area images

When you paste an image into a `lightning-input-rich-text`, Salesforce's component catches the paste event and uploads the image to `/servlet/rtaImage?refid=0EM...`. Those URLs:

- **Are not** real `ContentDocument` records
- **Cannot** be referenced by `ConnectApi.InlineImageSegmentInput`, which requires a `069...` ContentDocumentId
- **Don't render** reliably across users and sessions

So even if you find the ConnectApi inline image docs and think "aha, just pass the refid", it doesn't work — the rta-image system is a different, older mechanism that ConnectApi ignores.

### Dead end 3: Trying to upload the rta-image bytes yourself

You might think "ok, I'll fetch the bytes from the rtaImage URL server-side and re-upload as a ContentVersion." **It doesn't work.** The `/servlet/rtaImage` endpoint returns `404` from `PageReference.getContent()` even with a valid session — the rta-image system expects an `eid` parameter tied to the original browser session, and the image is only accessible from the same client context that created it.

### Dead end 4: Trying to intercept the paste in the LWC's own paste handler

You'd think attaching a `paste` listener to your LWC's container div would let you catch the image before Salesforce's handler runs. **It doesn't.** Salesforce's `lightning-input-rich-text` has its own internal `ql-clipboard` div inside its shadow DOM that catches the paste before it bubbles up to your component. Your handler never fires.

---

## How this package solves it

### The trick: document-level paste capture + focus tracking

1. **Attach a `paste` listener to `document` in the capture phase** (`{ capture: true }`) — capture phase runs top-down before any descendant's handler, so we run **before** `lightning-input-rich-text` sees the event.

2. **Track focus state on our LWC host element** using `focusin`/`focusout`. These are composed events that cross shadow root boundaries, so they reach our component from inside the shadow DOM. This tells us "the paste is for our editor" because Lightning Web Security retargets composed event paths at the outermost shadow root, which would otherwise prevent us from inspecting the paste target directly.

3. **When our handler fires for a paste with an image and focus is in our editor:**
   - `preventDefault()` + `stopImmediatePropagation()` — kills the event before Salesforce's rta-image upload runs
   - Read the image binary from `clipboardData.items`
   - Upload it as a real `ContentVersion` via an `@AuraEnabled` Apex method
   - Get back a `069...` `ContentDocumentId`
   - Insert an `<img src="/sfc/servlet.shepherd/document/download/069...">` tag into the editor value

4. **Quill (the editor backing `lightning-input-rich-text`) strips custom `data-*` attributes** during sanitization but preserves `src` unchanged. That's why we encode the `ContentDocumentId` in the src URL itself.

5. **On Submit**, the HTML is passed to an invocable Apex action that parses the `<img>` tags with a forward-walking segment builder, extracts the `069...` IDs from each src, and emits `ConnectApi.InlineImageSegmentInput` message segments in document order.

6. **`ConnectApi.ChatterFeeds.postFeedElement()`** creates a real `FeedItem` with native inline images that render for all viewers.

---

## Components

| Component | Type | Purpose |
|-----------|------|---------|
| `ChatterInlineImagesController` | Apex (`@AuraEnabled`) | Uploads pasted images as `ContentVersion` records, resolves user/group names for the mention picker. |
| `ChatterInlineImagePoster` | Apex (`@InvocableMethod`) | Parses rich text HTML, builds ConnectApi message segments (text + inline image + mention), posts the FeedItem. |
| `chatterImageEditor` | LWC (Flow Screen) | Rich text editor with document-level paste capture, focus tracking, and optional mention picker. |
| `Chatter_Inline_Image_Post_Demo` | Flow | Minimal 2-element demo flow (Screen → Post to Chatter). |
| `Post_Inline_Comment` | Quick Action (Case) | Launches the demo flow from a Case page. |

Plus two Apex test classes (`ChatterInlineImagesControllerTest`, `ChatterInlineImagePosterTest`) with ~90% code coverage for production deployment.

---

## Installation

### Prerequisites

- Salesforce CLI (`sf`)
- An authenticated org (sandbox recommended for first install)

### Deploy

```bash
git clone https://github.com/neilcorp2kx/salesforce-ChatterInlineImages.git
cd salesforce-ChatterInlineImages
sf project deploy start --manifest manifest/package.xml --target-org <your-org-alias>
```

Run the tests to verify coverage:

```bash
sf apex run test --class-names ChatterInlineImagesControllerTest --class-names ChatterInlineImagePosterTest --target-org <your-org-alias> --result-format human --wait 10
```

### Add the quick action to a Case page layout

1. **Setup > Object Manager > Case > Page Layouts**
2. Edit your layout, find the **Mobile & Lightning Actions** section
3. Drag **Post Inline Comment** onto the **Salesforce Mobile and Lightning Experience Actions** area
4. Save

Open any Case → click **Post Inline Comment** in the action bar → the flow launches in a modal → paste a screenshot → post.

---

## Adapt to other objects

The flow is object-agnostic — it just uses `{!recordId}` from flow context. To add the button to another object:

1. **Setup > Object Manager > [Your Object] > Buttons, Links, and Actions**
2. **New Action**
   - **Action Type:** Flow
   - **Flow:** Chatter Inline Image Post Demo
   - **Label:** whatever you want
3. Add the action to the page layout

---

## Customize the LWC

The `chatterImageEditor` LWC exposes these flow screen properties:

| Property | Type | Default | Purpose |
|----------|------|---------|---------|
| `recordId` | String | *(required)* | The record to link uploaded images to and post the FeedItem on |
| `label` | String | `Comment` | Field label above the editor |
| `placeholder` | String | `Type your comment here...` | Placeholder text |
| `required` | Boolean | `false` | Block Next/Finish if the editor is empty |
| `disableAdvancedTools` | Boolean | `false` | Show only basic formatting in the toolbar |
| `hideVisibilitySelector` | Boolean | `false` | Hide the `To` dropdown |
| `hideMentionButton` | Boolean | `false` | Hide the Mention button if you don't want mention support |
| `defaultVisibility` | String | `InternalUsers` | `InternalUsers` or `AllUsers` |
| `richTextValue` | String | *(output)* | Read this in subsequent flow elements to get the HTML to post |
| `selectedVisibility` | String | *(output)* | Read this to get the user's choice |

---

## Known limitations

- **Pasted images are appended to the end** of the editor, not inserted at cursor position. We block Quill's paste handler entirely, so Quill has no idea about the image — it just sees the updated value and re-renders. Mentions *do* insert at cursor position (via a different technique using `execCommand`).
- **Mention picker uses a button**, not inline `@` typeahead. Inline typeahead would require hooking into Quill's internal change events and positioning an overlay at the caret, which is painful across shadow DOM boundaries. A button with a record picker is 1/5 the work.
- **Selectors target Salesforce's internal DOM**. The focus-tracking and capture-phase approach doesn't depend on internal APIs, so it should be stable, but if Salesforce ever changes how `lightning-input-rich-text` dispatches paste events, this could break.
- **External user visibility**: If you post with `AllUsers` visibility, the uploaded images need their `ContentDocumentLink.Visibility` set to `AllUsers` too. The invocable does this automatically.
- **No drag-drop support** yet. Paste only.

---

## Credits

Built by [Neil Blackman](https://github.com/neilcorp2kx) at Trusted Tech Team after discovering the idea still wasn't delivered 7 years after it was first filed. Shared back to the community with the hope that nobody else has to rediscover the rta-image / ConnectApi / Quill sanitization / Lightning Web Security path-retargeting maze.

## License

MIT — see [LICENSE](LICENSE).
