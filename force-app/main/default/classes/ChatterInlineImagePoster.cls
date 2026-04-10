/**
 * @description Invocable action that posts a Chatter FeedItem with native
 *              inline images (and optional @mentions) via ConnectApi. Parses
 *              rich text HTML from the chatterImageEditor LWC and emits
 *              alternating text + inline image + mention message segments
 *              in document order so the resulting feed item renders inline
 *              in the native Chatter feed — something the standard
 *              FeedItem.Body text field cannot do on its own.
 *
 *              Why this exists: Salesforce's lightning-input-rich-text
 *              intercepts pasted images and uploads them as legacy Rich Text
 *              Area images with /servlet/rtaImage?refid=... URLs. Those
 *              cannot be referenced by ConnectApi as inline image segments
 *              — only real ContentDocumentIds (069... key prefix) can. The
 *              companion LWC defeats the rta-image interception by catching
 *              paste events at document-level capture phase BEFORE
 *              lightning-input-rich-text sees them, uploading the image as
 *              a real ContentVersion, and inserting an <img src="...069..."
 *              tag into the editor value. This Apex class then parses those
 *              src URLs to build InlineImageSegmentInput objects.
 *
 *              For @mentions, the LWC inserts <a href="/005..."> anchors
 *              (using 005 for User or 0F9 for CollaborationGroup). This
 *              class emits MentionSegmentInput for each one.
 *
 *              Part of the chatter-inline-images sharing package.
 *              https://github.com/neilcorp2kx/salesforce-ChatterInlineImages
 */
public with sharing class ChatterInlineImagePoster {

    // Combined pattern: matches either an <img> tag (for inline images) or
    // an <a href="/{id}"> mention anchor (for user/group mentions), whichever
    // comes first in the HTML. Alternation lets us walk the HTML once in
    // document order.
    //
    // Group 1: img src  (set when an img tag matched)
    // Group 2: mention record id from href  (set when an anchor tag matched)
    //          Accepts 005 (User) and 0F9 (CollaborationGroup) key prefixes.
    private static final Pattern MARKER_PATTERN = Pattern.compile(
        '(?is)' +
        '<img[^>]*\\bsrc\\s*=\\s*["\\\']([^"\\\']+)["\\\'][^>]*/?\\s*>' +
        '|' +
        '<a[^>]*\\bhref\\s*=\\s*["\\\']/(0(?:05|F9)[a-zA-Z0-9]{12,15})["\\\'][^>]*>[^<]*</a>'
    );

    // Extract a 15- or 18-char ContentDocumentId (069 prefix) from an img src
    private static final Pattern CONTENT_DOC_ID_PATTERN = Pattern.compile(
        '(069[a-zA-Z0-9]{12}(?:[a-zA-Z0-9]{3})?)'
    );

    @InvocableMethod(
        label='Post Chatter FeedItem with Inline Images'
        description='Posts a Chatter FeedItem via ConnectApi with inline images and optional @mentions parsed from rich text HTML produced by the chatterImageEditor LWC.'
        category='Chatter'
    )
    public static List<Result> postFeedItems(List<Request> requests) {
        List<Result> results = new List<Result>();

        for (Request req : requests) {
            Result r = new Result();
            try {
                if (req.parentId == null) {
                    throw new IllegalArgumentException('parentId is required');
                }
                if (String.isBlank(req.richTextHtml)) {
                    throw new IllegalArgumentException('richTextHtml is required');
                }

                ConnectApi.FeedItemVisibilityType visibility = resolveVisibility(req.visibility);

                Set<Id> imageDocIds = new Set<Id>();
                List<ConnectApi.MessageSegmentInput> segments =
                    buildSegments(req.richTextHtml, imageDocIds);

                if (segments.isEmpty()) {
                    ConnectApi.TextSegmentInput empty = new ConnectApi.TextSegmentInput();
                    empty.text = '(no content)';
                    segments.add(empty);
                }

                updateContentDocumentLinkVisibility(imageDocIds, req.parentId, visibility);

                ConnectApi.FeedItemInput feedItemInput = new ConnectApi.FeedItemInput();
                feedItemInput.subjectId = req.parentId;
                feedItemInput.feedElementType = ConnectApi.FeedElementType.FeedItem;
                feedItemInput.visibility = visibility;

                ConnectApi.MessageBodyInput body = new ConnectApi.MessageBodyInput();
                body.messageSegments = segments;
                feedItemInput.body = body;

                ConnectApi.FeedElement posted =
                    ConnectApi.ChatterFeeds.postFeedElement(null, feedItemInput);

                r.success = true;
                r.postId = posted.id;
            } catch (Exception e) {
                r.success = false;
                r.errorMessage = e.getMessage();
            }
            results.add(r);
        }

        return results;
    }

    // ─── Segment Builder (testable in isolation) ─────────────────────────
    // Forward-walks the HTML emitting a text segment for each HTML chunk
    // between markers and the matching InlineImage / Mention segment for
    // each marker. Output is in document order.

    @TestVisible
    private static List<ConnectApi.MessageSegmentInput> buildSegments(
        String html, Set<Id> outContentDocumentIds
    ) {
        List<ConnectApi.MessageSegmentInput> segments = new List<ConnectApi.MessageSegmentInput>();
        if (String.isBlank(html)) return segments;

        Matcher m = MARKER_PATTERN.matcher(html);
        Integer lastEnd = 0;

        while (m.find()) {
            String imgSrc = m.group(1);
            String mentionRecordId = m.group(2);

            ConnectApi.MessageSegmentInput markerSegment = null;

            if (imgSrc != null) {
                Id docId = extractContentDocumentId(imgSrc);
                if (docId != null) {
                    if (outContentDocumentIds != null) {
                        outContentDocumentIds.add(docId);
                    }
                    ConnectApi.InlineImageSegmentInput imgSeg = new ConnectApi.InlineImageSegmentInput();
                    imgSeg.fileId = docId;
                    imgSeg.altText = 'Inline image';
                    markerSegment = imgSeg;
                }
            } else if (mentionRecordId != null) {
                try {
                    ConnectApi.MentionSegmentInput mentionSeg = new ConnectApi.MentionSegmentInput();
                    mentionSeg.id = Id.valueOf(mentionRecordId);
                    markerSegment = mentionSeg;
                } catch (Exception e) {
                    // Malformed id — fall through and keep the anchor's text as text
                }
            }

            if (markerSegment == null) {
                continue;
            }

            appendTextSegment(segments, html.substring(lastEnd, m.start()));
            segments.add(markerSegment);
            lastEnd = m.end();
        }

        appendTextSegment(segments, html.substring(lastEnd));
        return segments;
    }

    private static Id extractContentDocumentId(String src) {
        if (String.isBlank(src)) return null;
        Matcher idMatcher = CONTENT_DOC_ID_PATTERN.matcher(src);
        if (!idMatcher.find()) return null;
        try {
            return Id.valueOf(idMatcher.group(1));
        } catch (Exception e) {
            return null;
        }
    }

    private static void appendTextSegment(
        List<ConnectApi.MessageSegmentInput> segments, String rawHtml
    ) {
        String plain = stripHtmlToPlainText(rawHtml);
        if (String.isBlank(plain)) return;
        ConnectApi.TextSegmentInput seg = new ConnectApi.TextSegmentInput();
        seg.text = plain;
        segments.add(seg);
    }

    /**
     * Strip HTML tags and decode common entities. Preserves line breaks from
     * <br>, </p>, </div>, </li> so the posted text reads naturally.
     */
    @TestVisible
    private static String stripHtmlToPlainText(String html) {
        if (String.isBlank(html)) return '';

        String text = html;
        text = text.replaceAll('(?i)<br\\s*/?\\s*>', '\n');
        text = text.replaceAll('(?i)</p\\s*>', '\n');
        text = text.replaceAll('(?i)</div\\s*>', '\n');
        text = text.replaceAll('(?i)</li\\s*>', '\n');
        text = text.replaceAll('<[^>]+>', '');
        text = text.replace('&nbsp;', ' ')
                   .replace('&amp;', '&')
                   .replace('&lt;', '<')
                   .replace('&gt;', '>')
                   .replace('&quot;', '"')
                   .replace('&#39;', '\'')
                   .replace('&apos;', '\'');
        text = text.replaceAll('\\n{3,}', '\n\n');
        return text.trim();
    }

    @TestVisible
    private static ConnectApi.FeedItemVisibilityType resolveVisibility(String visibility) {
        if (String.isBlank(visibility)) {
            return ConnectApi.FeedItemVisibilityType.InternalUsers;
        }
        String v = visibility.toLowerCase();
        if (v == 'allusers' || v == 'all' || v == 'external') {
            return ConnectApi.FeedItemVisibilityType.AllUsers;
        }
        return ConnectApi.FeedItemVisibilityType.InternalUsers;
    }

    /**
     * Align CDL visibility with the post visibility so external users can
     * see inline images when the post is AllUsers.
     */
    private static void updateContentDocumentLinkVisibility(
        Set<Id> contentDocumentIds,
        Id parentId,
        ConnectApi.FeedItemVisibilityType visibility
    ) {
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) return;

        String targetVisibility =
            visibility == ConnectApi.FeedItemVisibilityType.AllUsers ? 'AllUsers' : 'InternalUsers';

        List<ContentDocumentLink> links = [
            SELECT Id, Visibility
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :contentDocumentIds
            AND LinkedEntityId = :parentId
        ];

        List<ContentDocumentLink> toUpdate = new List<ContentDocumentLink>();
        for (ContentDocumentLink link : links) {
            if (link.Visibility != targetVisibility) {
                link.Visibility = targetVisibility;
                toUpdate.add(link);
            }
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    // ─── Request / Result Wrappers ────────────────────────────────────

    public class Request {
        @InvocableVariable(
            label='Parent Record Id'
            description='The record to post the FeedItem to (Case, Account, custom object, etc.)'
            required=true
        )
        public Id parentId;

        @InvocableVariable(
            label='Rich Text HTML'
            description='HTML from chatterImageEditor LWC. Any <img> tag whose src contains a ContentDocumentId (069...) becomes an inline image segment. Any <a href="/{id}"> with a 005 or 0F9 href becomes a mention segment.'
            required=true
        )
        public String richTextHtml;

        @InvocableVariable(
            label='Visibility'
            description='InternalUsers or AllUsers. Defaults to InternalUsers.'
        )
        public String visibility;
    }

    public class Result {
        @InvocableVariable(label='Post Id' description='The created FeedItem Id')
        public Id postId;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }
}
