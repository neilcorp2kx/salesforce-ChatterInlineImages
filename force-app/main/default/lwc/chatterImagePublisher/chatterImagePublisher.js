import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import uploadImage from '@salesforce/apex/ChatterInlineImagesController.uploadImage';
import getMentionableName from '@salesforce/apex/ChatterInlineImagesController.getMentionableName';
import postFeedItem from '@salesforce/apex/ChatterInlineImagesController.postFeedItem';

const DEFAULT_FORMATS = [
    'font', 'size', 'bold', 'italic', 'underline', 'strike',
    'list', 'indent', 'align', 'link', 'image', 'clean',
    'header', 'color', 'background', 'code', 'code-block'
];

const BASIC_FORMATS = ['bold', 'italic', 'underline', 'list', 'link'];

const VISIBILITY_OPTIONS = [
    { label: 'Internal Users Only', value: 'InternalUsers' },
    { label: 'All with Access',     value: 'AllUsers' }
];

export default class ChatterImagePublisher extends LightningElement {

    @api recordId;
    @api placeholder = 'Type a message. Paste screenshots directly with Ctrl+V...';
    @api disableAdvancedTools = false;
    @api hideVisibilitySelector = false;
    @api hideMentionButton = false;
    @api defaultVisibility = 'InternalUsers';

    @track richTextValue = '';
    @track isUploading = false;
    @track isPosting = false;
    @track uploadError;
    @track postError;
    @track showMentionPicker = false;
    @track isResolvingMention = false;

    _visibilityValue;
    _pasteHandler;
    _hasFocus = false;
    _pasteCounter = 0;

    static MENTION_MARKER = '‌‍‌‍‌';

    mentionFilter = {
        criteria: [{ fieldPath: 'IsActive', operator: 'eq', value: true }]
    };

    connectedCallback() {
        this._visibilityValue = this.defaultVisibility || 'InternalUsers';
        this.addEventListener('focusin',  () => { this._hasFocus = true; });
        this.addEventListener('focusout', () => { this._hasFocus = false; });
        this._pasteHandler = (event) => this._onDocumentPaste(event);
        document.addEventListener('paste', this._pasteHandler, true);
    }

    disconnectedCallback() {
        if (this._pasteHandler) {
            document.removeEventListener('paste', this._pasteHandler, true);
            this._pasteHandler = null;
        }
    }

    get showVisibilitySelector() { return !this.hideVisibilitySelector; }
    get showMentionButton()      { return !this.hideMentionButton; }
    get currentVisibility()      { return this._visibilityValue || 'InternalUsers'; }
    get formats()                { return this.disableAdvancedTools ? BASIC_FORMATS : DEFAULT_FORMATS; }
    get visibilityOptions()      { return VISIBILITY_OPTIONS; }

    handleRichTextChange(event) {
        this.richTextValue = event.target.value;
        this.postError = undefined;
    }

    handleVisibilityChange(event) {
        this._visibilityValue = event.detail.value;
    }

    handleMentionMouseDown(event) {
        event.preventDefault();
        try {
            document.execCommand('insertText', false, ChatterImagePublisher.MENTION_MARKER);
        } catch (e) { /* ignore */ }
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
            const mentionHtml = `&nbsp;<a href="/${recordId}">@${name}</a>&nbsp;`;
            const current = this.richTextValue || '';
            const marker = ChatterImagePublisher.MENTION_MARKER;
            let updated;
            if (current.indexOf(marker) >= 0) {
                updated = current.split(marker).join(mentionHtml);
            } else {
                const blockMatch = current.match(/<\/(p|div|li|h[1-6])>\s*$/i);
                updated = blockMatch
                    ? current.substring(0, blockMatch.index) + mentionHtml + current.substring(blockMatch.index)
                    : current + mentionHtml;
            }
            this.richTextValue = updated;
            this.showMentionPicker = false;
        } catch (err) {
            this.uploadError = 'Failed to add mention: ' + this._reduceError(err);
        } finally {
            this.isResolvingMention = false;
        }
    }

    async handlePost() {
        const val = (this.richTextValue || '').trim();
        if (!val || val === '<p><br></p>') {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Cannot post',
                message: 'Please enter a message before posting.',
                variant: 'warning'
            }));
            return;
        }
        if (this.isUploading) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Please wait',
                message: 'Image is still uploading.',
                variant: 'warning'
            }));
            return;
        }

        this.isPosting = true;
        this.postError = undefined;
        try {
            await postFeedItem({
                parentId:    this.recordId,
                richTextHtml: this.richTextValue,
                visibility:  this.currentVisibility
            });
            this.richTextValue = '';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Posted',
                message: 'Your message was posted to Chatter.',
                variant: 'success'
            }));
        } catch (err) {
            this.postError = this._reduceError(err);
        } finally {
            this.isPosting = false;
        }
    }

    async _onDocumentPaste(event) {
        if (!this._hasFocus) return;
        const clipboardData = event.clipboardData;
        if (!clipboardData?.items) return;
        let imageFile = null;
        for (let i = 0; i < clipboardData.items.length; i++) {
            const item = clipboardData.items[i];
            if (item.type?.startsWith('image/')) {
                imageFile = item.getAsFile();
                break;
            }
        }
        if (!imageFile) return;
        event.preventDefault();
        event.stopPropagation();
        if (event.stopImmediatePropagation) event.stopImmediatePropagation();
        await this._uploadAndInsertFile(imageFile);
    }

    async _uploadAndInsertFile(file) {
        if (!this.recordId) {
            this.uploadError = 'Cannot upload image: record Id not available.';
            return;
        }
        this.isUploading = true;
        this.uploadError = undefined;
        try {
            const base64 = await this._blobToBase64(file);
            const extension = this._extensionForMime(file.type);
            const fileName = file.name?.length > 0
                ? file.name
                : `image-${this._timestampForFileName()}-${++this._pasteCounter}.${extension}`;
            const result = await uploadImage({ parentId: this.recordId, fileName, base64Data: base64 });
            const imgTag = `<img src="${result.downloadUrl}" alt="${fileName}" />`;
            this.richTextValue = (this.richTextValue || '') + imgTag;
        } catch (err) {
            this.uploadError = 'Failed to upload image: ' + this._reduceError(err);
        } finally {
            this.isUploading = false;
        }
    }

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
        if (lower.includes('jpeg') || lower.includes('jpg')) return 'jpg';
        if (lower.includes('gif')) return 'gif';
        if (lower.includes('webp')) return 'webp';
        if (lower.includes('svg')) return 'svg';
        return 'png';
    }

    _timestampForFileName() {
        const d = new Date();
        const pad = (n) => String(n).padStart(2, '0');
        return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
    }

    _reduceError(error) {
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        return 'Unknown error';
    }
}
