/**
 * chatterImageEditor
 *
 * Flow screen rich text editor that lets users paste screenshots and have
 * them post inline to the native Chatter feed.
 *
 * The trick: Salesforce's lightning-input-rich-text intercepts pasted
 * images and uploads them as legacy Rich Text Area images with
 * /servlet/rtaImage?refid=... URLs. Those can't be referenced as ConnectApi
 * inline image segments. So we catch the paste at document-level capture
 * phase BEFORE Salesforce's handler runs, upload the image ourselves as a
 * real ContentVersion, and insert an <img src="/sfc/servlet.shepherd/document/download/069...">
 * tag into the editor value. The companion ChatterInlineImagePoster Apex
 * then parses those 069 Ids back out and builds real inline image segments.
 *
 * Optionally supports @mentions via a record picker button that inserts
 * <a href="/{recordId}">@Name</a> anchors, which the poster turns into
 * ConnectApi MentionSegments.
 *
 * Part of the chatter-inline-images sharing package.
 * https://github.com/neilcorp2kx/salesforce-ChatterInlineImages
 */
import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import uploadImage from '@salesforce/apex/ChatterInlineImagesController.uploadImage';
import getMentionableName from '@salesforce/apex/ChatterInlineImagesController.getMentionableName';

const DEFAULT_FORMATS = [
    'font', 'size', 'bold', 'italic', 'underline', 'strike',
    'list', 'indent', 'align', 'link', 'image', 'clean',
    'header', 'color', 'background', 'code', 'code-block'
];

const BASIC_FORMATS = [
    'bold', 'italic', 'underline', 'list', 'link'
];

const VISIBILITY_OPTIONS = [
    { label: 'Internal Users Only', value: 'InternalUsers' },
    { label: 'All with Access',     value: 'AllUsers' }
];

export default class ChatterImageEditor extends LightningElement {

    // ── Flow inputs ──────────────────────────────────────────────────────
    @api recordId;
    @api label = 'Comment';
    @api placeholder = 'Type your comment here. Paste screenshots directly with Ctrl+V...';
    @api required = false;
    @api disableAdvancedTools = false;
    @api hideVisibilitySelector = false;
    @api hideMentionButton = false;
    @api defaultVisibility = 'InternalUsers';

    // ── Flow input/output (bidirectional) ────────────────────────────────
    @api richTextValue = '';
    @api selectedVisibility;

    // ── Internal state ───────────────────────────────────────────────────
    isUploading = false;
    uploadError;
    showMentionPicker = false;
    isResolvingMention = false;
    _visibilityValue;
    _pasteHandler;
    _hasFocus = false;
    _pasteCounter = 0;

    mentionFilter = {
        criteria: [
            { fieldPath: 'IsActive', operator: 'eq', value: true }
        ]
    };

    // Zero-width marker we drop at the caret when the Mention button is
    // pressed, so we can insert the mention at cursor position after the
    // user picks a record (picker focus would otherwise clobber the caret).
    static MENTION_MARKER = '\u200C\u200D\u200C\u200D\u200C';

    connectedCallback() {
        this._visibilityValue =
            this.selectedVisibility || this.defaultVisibility || 'InternalUsers';
        this.dispatchEvent(
            new FlowAttributeChangeEvent('selectedVisibility', this._visibilityValue)
        );

        // focusin/focusout are composed events that cross shadow root
        // boundaries, so they reach our host element. We use this flag in
        // the document-level paste handler to decide whether a paste
        // targets our editor — Lightning Web Security retargets composed
        // event paths at the outermost shadow root, so we can't inspect
        // the paste event's target directly.
        this.addEventListener('focusin', () => { this._hasFocus = true; });
        this.addEventListener('focusout', () => { this._hasFocus = false; });

        // Document-level paste listener in CAPTURE phase runs top-down
        // before lightning-input-rich-text's handler, so we intercept the
        // image before Salesforce converts it to a /servlet/rtaImage URL.
        this._pasteHandler = (event) => this._onDocumentPaste(event);
        document.addEventListener('paste', this._pasteHandler, true);
    }

    disconnectedCallback() {
        if (this._pasteHandler) {
            document.removeEventListener('paste', this._pasteHandler, true);
            this._pasteHandler = null;
        }
    }

    get showVisibilitySelector() {
        return !this.hideVisibilitySelector;
    }

    get showMentionButton() {
        return !this.hideMentionButton;
    }

    get currentVisibility() {
        return this._visibilityValue || this.defaultVisibility || 'InternalUsers';
    }

    get formats() {
        return this.disableAdvancedTools ? BASIC_FORMATS : DEFAULT_FORMATS;
    }

    get visibilityOptions() {
        return VISIBILITY_OPTIONS;
    }

    // ── Event handlers ───────────────────────────────────────────────────

    handleRichTextChange(event) {
        const newValue = event.target.value;
        this.richTextValue = newValue;
        this.dispatchEvent(new FlowAttributeChangeEvent('richTextValue', newValue));
    }

    handleVisibilityChange(event) {
        this._visibilityValue = event.detail.value;
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedVisibility', this._visibilityValue));
    }

    handleMentionMouseDown(event) {
        // preventDefault keeps focus in the editor long enough for
        // document.execCommand('insertText') to operate on its active selection.
        event.preventDefault();
        try {
            document.execCommand('insertText', false, ChatterImageEditor.MENTION_MARKER);
        } catch (e) {
            // Ignore — we'll fall back to smart block insertion on pick.
        }
    }

    handleToggleMentionPicker() {
        this.showMentionPicker = !this.showMentionPicker;
    }

    async handleMentionChange(event) {
        const recordId = event.detail?.recordId;
        if (!recordId) return;

        this.isResolvingMention = true;
        try {
            const name = await getMentionableName({ recordId });
            if (!name) {
                this.uploadError = 'Could not resolve user/group name.';
                return;
            }

            // Encode the mention as an anchor whose href starts with /{recordId}.
            // Quill preserves <a href=...> unchanged, so the Id survives the
            // round-trip through the editor. The invocable action regex-parses
            // the Id back out of the href and emits a MentionSegmentInput.
            const mentionHtml = `&nbsp;<a href="/${recordId}">@${name}</a>&nbsp;`;
            const current = this.richTextValue || '';
            const marker = ChatterImageEditor.MENTION_MARKER;

            let updated;
            if (current.indexOf(marker) >= 0) {
                // Cursor marker was dropped — replace it in place
                updated = current.split(marker).join(mentionHtml);
            } else {
                // Fallback: insert before the last closing block tag so the
                // mention lands inside the last paragraph rather than dangling.
                const blockMatch = current.match(/<\/(p|div|li|h[1-6])>\s*$/i);
                updated = blockMatch
                    ? current.substring(0, blockMatch.index) + mentionHtml + current.substring(blockMatch.index)
                    : current + mentionHtml;
            }

            this.richTextValue = updated;
            this.dispatchEvent(new FlowAttributeChangeEvent('richTextValue', updated));
            this.showMentionPicker = false;
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('[chatterImageEditor] mention insert failed', err);
            this.uploadError = 'Failed to add mention: ' + this._reduceError(err);
        } finally {
            this.isResolvingMention = false;
        }
    }

    async _onDocumentPaste(event) {
        if (!this._hasFocus) {
            return;
        }

        const clipboardData = event.clipboardData;
        if (!clipboardData || !clipboardData.items) {
            return;
        }

        let imageFile = null;
        for (let i = 0; i < clipboardData.items.length; i++) {
            const item = clipboardData.items[i];
            if (item.type && item.type.startsWith('image/')) {
                imageFile = item.getAsFile();
                break;
            }
        }

        if (!imageFile) {
            return;
        }

        // Block Salesforce's rta-image handler from running after us
        event.preventDefault();
        event.stopPropagation();
        if (event.stopImmediatePropagation) {
            event.stopImmediatePropagation();
        }

        await this._uploadAndInsertFile(imageFile);
    }

    async _uploadAndInsertFile(file) {
        if (!this.recordId) {
            this.uploadError = 'Cannot upload image: parent record Id not available in flow context.';
            return;
        }

        this.isUploading = true;
        this.uploadError = undefined;

        try {
            const base64 = await this._blobToBase64(file);
            const extension = this._extensionForMime(file.type);
            const fileName = file.name && file.name.length > 0
                ? file.name
                : `image-${this._timestampForFileName()}-${++this._pasteCounter}.${extension}`;

            const result = await uploadImage({
                parentId: this.recordId,
                fileName: fileName,
                base64Data: base64
            });

            // Append the img tag. We can't insert at cursor because we
            // blocked Quill's paste handler, so Quill doesn't know about
            // the image — it just receives the updated value and re-renders.
            const imgTag = `<img src="${result.downloadUrl}" alt="${fileName}" />`;
            const updated = (this.richTextValue || '') + imgTag;

            this.richTextValue = updated;
            this.dispatchEvent(new FlowAttributeChangeEvent('richTextValue', updated));
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('[chatterImageEditor] upload failed', err);
            this.uploadError = 'Failed to upload image: ' + this._reduceError(err);
        } finally {
            this.isUploading = false;
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    _blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => {
                const result = reader.result || '';
                const comma = result.indexOf(',');
                resolve(comma >= 0 ? result.substring(comma + 1) : result);
            };
            reader.onerror = reject;
            reader.readAsDataURL(blob);
        });
    }

    _extensionForMime(mimeType) {
        if (!mimeType) return 'png';
        const lower = mimeType.toLowerCase();
        if (lower.indexOf('jpeg') >= 0 || lower.indexOf('jpg') >= 0) return 'jpg';
        if (lower.indexOf('gif') >= 0) return 'gif';
        if (lower.indexOf('webp') >= 0) return 'webp';
        if (lower.indexOf('svg') >= 0) return 'svg';
        return 'png';
    }

    _timestampForFileName() {
        const d = new Date();
        const pad = (n) => String(n).padStart(2, '0');
        return d.getFullYear()
            + pad(d.getMonth() + 1)
            + pad(d.getDate())
            + '-'
            + pad(d.getHours())
            + pad(d.getMinutes())
            + pad(d.getSeconds());
    }

    _reduceError(error) {
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        return 'Unknown error';
    }

    // ── Flow validation hook ─────────────────────────────────────────────

    @api
    validate() {
        if (this.isUploading) {
            return {
                isValid: false,
                errorMessage: 'Please wait — image is still uploading.'
            };
        }

        if (this.required) {
            const val = (this.richTextValue || '').trim();
            if (!val || val === '<p><br></p>') {
                return {
                    isValid: false,
                    errorMessage: (this.label || 'Comment') + ' is required.'
                };
            }
        }

        return { isValid: true };
    }
}
