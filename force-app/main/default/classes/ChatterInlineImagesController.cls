/**
 * @description Apex controller for the chatterImageEditor LWC. Handles:
 *              - Uploading pasted/dropped images as ContentVersion records
 *                linked to the parent record. Returns a document download
 *                URL that embeds the ContentDocumentId, which
 *                ChatterInlineImagePoster later parses out of <img src="...">
 *                to build ConnectApi inline image segments.
 *              - Resolving User / Chatter Group names for the mention picker
 *                (the record picker in the LWC only returns the Id).
 *
 *              Part of the chatter-inline-images sharing package.
 *              https://github.com/neilcorp2kx/salesforce-ChatterInlineImages
 */
public with sharing class ChatterInlineImagesController {

    public class UploadResult {
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String downloadUrl;
    }

    /**
     * Uploads a base64-encoded image as a ContentVersion linked to parentId
     * and returns a document download URL that the LWC can embed in an
     * <img src="..."> tag. The invocable poster parses the ContentDocumentId
     * back out of the src when building inline image segments.
     */
    @AuraEnabled
    public static UploadResult uploadImage(Id parentId, String fileName, String base64Data) {
        if (parentId == null) {
            throw new AuraHandledException('Parent record Id is required.');
        }
        if (String.isBlank(base64Data)) {
            throw new AuraHandledException('Image data is required.');
        }

        String safeName = String.isBlank(fileName)
            ? ('pasted-image-' + Datetime.now().getTime() + '.png')
            : fileName;

        ContentVersion cv = new ContentVersion();
        cv.Title = safeName;
        cv.PathOnClient = safeName;
        cv.VersionData = EncodingUtil.base64Decode(base64Data);
        cv.FirstPublishLocationId = parentId;

        try {
            insert cv;
        } catch (DmlException e) {
            throw new AuraHandledException('Failed to upload image: ' + e.getDmlMessage(0));
        }

        ContentVersion inserted = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
            LIMIT 1
        ];

        UploadResult result = new UploadResult();
        result.contentDocumentId = inserted.ContentDocumentId;
        result.downloadUrl = '/sfc/servlet.shepherd/document/download/' + inserted.ContentDocumentId;
        return result;
    }

    /**
     * Returns the display name for a User (005) or CollaborationGroup (0F9).
     * Used by the mention picker in the LWC to resolve the picked record Id
     * into a name for the anchor text. Returns null for unsupported key
     * prefixes or records the running user can't see.
     */
    @AuraEnabled(cacheable=true)
    public static String getMentionableName(Id recordId) {
        if (recordId == null) return null;

        String prefix = String.valueOf(recordId).substring(0, 3);
        if (prefix == '005') {
            List<User> users = [SELECT Name FROM User WHERE Id = :recordId LIMIT 1];
            return users.isEmpty() ? null : users[0].Name;
        }
        if (prefix == '0F9') {
            List<CollaborationGroup> groups = [SELECT Name FROM CollaborationGroup WHERE Id = :recordId LIMIT 1];
            return groups.isEmpty() ? null : groups[0].Name;
        }
        return null;
    }
}
