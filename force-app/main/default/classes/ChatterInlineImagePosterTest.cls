/**
 * @description Tests for ChatterInlineImagePoster.
 *              Covers the segment-building logic directly (via the
 *              @TestVisible buildSegments method) plus the full invocable
 *              path through ConnectApi.ChatterFeeds.postFeedElement.
 */
@IsTest
private class ChatterInlineImagePosterTest {

    private static final String RED_PNG_B64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

    private static final String SAMPLE_DOC_ID_1 = '069000000000001AAA';
    private static final String SAMPLE_DOC_ID_2 = '069000000000002AAA';

    // ─── buildSegments: pure parsing logic ────────────────────────────

    @IsTest
    static void buildSegments_emptyHtmlReturnsEmptyList() {
        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(null, new Set<Id>());
        System.assertEquals(0, segments.size());

        segments = ChatterInlineImagePoster.buildSegments('', new Set<Id>());
        System.assertEquals(0, segments.size());
    }

    @IsTest
    static void buildSegments_textOnlyProducesSingleTextSegment() {
        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments('<p>Hello world</p>', new Set<Id>());

        System.assertEquals(1, segments.size(), 'one segment');
        System.assert(
            segments[0] instanceof ConnectApi.TextSegmentInput,
            'segment is a TextSegmentInput'
        );
    }

    @IsTest
    static void buildSegments_imgWithContentDocumentIdProducesInlineImageSegment() {
        Set<Id> docIds = new Set<Id>();
        String html = '<p>Before</p><p><img src="/sfc/servlet.shepherd/document/download/'
            + SAMPLE_DOC_ID_1 + '" /></p><p>After</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, docIds);

        System.assertEquals(3, segments.size(), 'text + image + text');
        System.assert(segments[0] instanceof ConnectApi.TextSegmentInput, 'segment 0 is text');
        System.assert(segments[1] instanceof ConnectApi.InlineImageSegmentInput, 'segment 1 is inline image');
        System.assert(segments[2] instanceof ConnectApi.TextSegmentInput, 'segment 2 is text');

        System.assertEquals(1, docIds.size(), 'one doc id collected');
        System.assert(docIds.contains(Id.valueOf(SAMPLE_DOC_ID_1)));
    }

    @IsTest
    static void buildSegments_imgWithoutContentDocumentIdIsSkipped() {
        // An img tag that doesn't have a 069 Id in its src should be skipped
        // (not turned into an orphan image segment).
        Set<Id> docIds = new Set<Id>();
        String html = '<p>Before</p><img src="https://example.com/not-a-sf-file.png" /><p>After</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, docIds);

        // The img tag is stripped with the surrounding HTML into text,
        // so we end up with one or two text segments depending on how
        // the surrounding paragraphs collapse.
        for (ConnectApi.MessageSegmentInput seg : segments) {
            System.assert(
                seg instanceof ConnectApi.TextSegmentInput,
                'no inline image segment produced'
            );
        }
        System.assertEquals(0, docIds.size(), 'no doc ids collected');
    }

    @IsTest
    static void buildSegments_mentionAnchorProducesMentionSegment() {
        Id userId = UserInfo.getUserId();
        String html = '<p>Hey <a href="/' + userId + '">@Test User</a>&nbsp; check this</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(3, segments.size(), 'text + mention + text');
        System.assert(segments[1] instanceof ConnectApi.MentionSegmentInput, 'segment 1 is a mention');

        ConnectApi.MentionSegmentInput mention = (ConnectApi.MentionSegmentInput) segments[1];
        System.assertEquals(userId, mention.id, 'mention references the correct user');
    }

    @IsTest
    static void buildSegments_mixedImageAndMentionPreservesDocumentOrder() {
        Id userId = UserInfo.getUserId();
        Set<Id> docIds = new Set<Id>();

        String html =
            '<p>Hey <a href="/' + userId + '">@Test</a>&nbsp; look:</p>' +
            '<p><img src="/sfc/servlet.shepherd/document/download/' + SAMPLE_DOC_ID_1 + '" /></p>' +
            '<p>And also:</p>' +
            '<p><img src="/sfc/servlet.shepherd/document/download/' + SAMPLE_DOC_ID_2 + '" /></p>' +
            '<p>Thanks</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, docIds);

        // Expected order: Text, Mention, Text, InlineImage, Text, InlineImage, Text
        System.assertEquals(7, segments.size(), 'expected 7 segments in order');
        System.assert(segments[0] instanceof ConnectApi.TextSegmentInput,        '0: text');
        System.assert(segments[1] instanceof ConnectApi.MentionSegmentInput,     '1: mention');
        System.assert(segments[2] instanceof ConnectApi.TextSegmentInput,        '2: text');
        System.assert(segments[3] instanceof ConnectApi.InlineImageSegmentInput, '3: image');
        System.assert(segments[4] instanceof ConnectApi.TextSegmentInput,        '4: text');
        System.assert(segments[5] instanceof ConnectApi.InlineImageSegmentInput, '5: image');
        System.assert(segments[6] instanceof ConnectApi.TextSegmentInput,        '6: text');

        System.assertEquals(2, docIds.size(), 'two doc ids collected');
    }

    @IsTest
    static void buildSegments_mentionAnchorWithMalformedIdIsSkipped() {
        // Href doesn't match 005/0F9 pattern — should not produce a mention
        String html = '<p>Try <a href="/001abc">not a user</a> here</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        for (ConnectApi.MessageSegmentInput seg : segments) {
            System.assert(
                !(seg instanceof ConnectApi.MentionSegmentInput),
                'no mention produced for malformed href'
            );
        }
    }

    // ─── stripHtmlToPlainText ─────────────────────────────────────────

    @IsTest
    static void stripHtmlToPlainText_stripsTagsAndDecodesEntities() {
        String result = ChatterInlineImagePoster.stripHtmlToPlainText(
            '<p>Hello <b>world</b> &amp; goodbye</p>'
        );
        System.assertEquals('Hello world & goodbye', result);
    }

    @IsTest
    static void stripHtmlToPlainText_preservesBlockBreaks() {
        String result = ChatterInlineImagePoster.stripHtmlToPlainText(
            '<p>Line 1</p><p>Line 2</p>'
        );
        System.assert(result.contains('\n'), 'block break preserved as newline');
        System.assert(result.contains('Line 1'));
        System.assert(result.contains('Line 2'));
    }

    @IsTest
    static void stripHtmlToPlainText_blankInputReturnsEmpty() {
        System.assertEquals('', ChatterInlineImagePoster.stripHtmlToPlainText(null));
        System.assertEquals('', ChatterInlineImagePoster.stripHtmlToPlainText(''));
    }

    // ─── resolveVisibility ─────────────────────────────────────────

    @IsTest
    static void resolveVisibility_defaultsToInternal() {
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.InternalUsers,
            ChatterInlineImagePoster.resolveVisibility(null)
        );
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.InternalUsers,
            ChatterInlineImagePoster.resolveVisibility('')
        );
    }

    @IsTest
    static void resolveVisibility_allUsersAliases() {
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.AllUsers,
            ChatterInlineImagePoster.resolveVisibility('AllUsers')
        );
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.AllUsers,
            ChatterInlineImagePoster.resolveVisibility('all')
        );
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.AllUsers,
            ChatterInlineImagePoster.resolveVisibility('external')
        );
    }

    @IsTest
    static void resolveVisibility_unknownDefaultsToInternal() {
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.InternalUsers,
            ChatterInlineImagePoster.resolveVisibility('something-weird')
        );
    }

    // ─── Invocable: validation + error handling ───────────────────────

    @IsTest
    static void postFeedItems_missingParentIdReturnsError() {
        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.richTextHtml = '<p>Hi</p>';

        Test.startTest();
        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success);
        System.assert(results[0].errorMessage.contains('parentId'));
    }

    @IsTest
    static void postFeedItems_missingHtmlReturnsError() {
        CollaborationGroup a = new CollaborationGroup(
            Name = 'Test Group ' + Datetime.now().getTime(),
            CollaborationType = 'Private'
        );
        insert a;

        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.parentId = a.Id;

        Test.startTest();
        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success);
        System.assert(results[0].errorMessage.contains('richTextHtml'));
    }

    // ─── Invocable: full end-to-end with real ConnectApi post ───────

    /**
     * ConnectApi.ChatterFeeds.postFeedElement requires SeeAllData=true in
     * tests because Salesforce's data-siloed test runner doesn't give it
     * access to the feed tables. The alternative is ConnectApi.setTestPostFeedElement
     * mocking, which is finicky — SeeAllData=true is simpler and these
     * tests run against the running user's own Chatter wall, so they
     * don't depend on any particular org data to exist.
     */
    @IsTest(SeeAllData=true)
    static void postFeedItems_textOnlyEndToEnd() {
        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.parentId = UserInfo.getUserId();
        req.richTextHtml = '<p>Hello from test</p>';
        // Posting to a user wall requires AllUsers visibility — the platform
        // rejects InternalUsers on user/group/DM feed posts.
        req.visibility = 'AllUsers';

        Test.startTest();
        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].success, 'post succeeded: ' + results[0].errorMessage);
        System.assertNotEquals(null, results[0].postId, 'postId returned');
    }

    @IsTest(SeeAllData=true)
    static void postFeedItems_withRealInlineImageEndToEnd() {
        Id parentId = UserInfo.getUserId();

        ChatterInlineImagesController.UploadResult upload =
            ChatterInlineImagesController.uploadImage(parentId, 'test.png', RED_PNG_B64);

        String html =
            '<p>Before image</p>' +
            '<p><img src="' + upload.downloadUrl + '" /></p>' +
            '<p>After image</p>';

        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.parentId = parentId;
        req.richTextHtml = html;
        req.visibility = 'AllUsers';

        Test.startTest();
        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'post succeeded: ' + results[0].errorMessage);
        System.assertNotEquals(null, results[0].postId);

        List<FeedAttachment> attachments = [
            SELECT Id, Type, RecordId
            FROM FeedAttachment
            WHERE FeedEntityId = :results[0].postId
        ];
        System.assertEquals(1, attachments.size(), 'one feed attachment created');
        System.assertEquals('InlineImage', attachments[0].Type);
    }
}
