#import "../src/render.h"
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

@interface TMQLThumbnailProvider : QLThumbnailProvider
@end

@implementation TMQLThumbnailProvider
- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest*)request completionHandler:(void(^)(QLThumbnailReply*, NSError*))handler
{
	// Use the proportions of a page (8.5 × 11) and size the font so that a line fits roughly 80 characters
	CGSize maxSize = request.maximumSize;
	CGSize size = maxSize.width * 11 / 8.5 > maxSize.height ? CGSizeMake(round(maxSize.height * 8.5 / 11), maxSize.height) : CGSizeMake(maxSize.width, round(maxSize.width * 11 / 8.5));
	CGFloat const inset    = round(size.width / 24);
	CGFloat const fontSize = MAX(size.width / 48, 1);

	NSAttributedString* str = TMQLCreateThumbnail(request.fileURL, fontSize, (size.height - 2*inset) / fontSize);
	if(!str)
		return handler(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil]);

	handler([QLThumbnailReply replyWithContextSize:size currentContextDrawingBlock:^BOOL{
		[NSColor.whiteColor set];
		NSRectFill(NSMakeRect(0, 0, size.width, size.height));
		[str drawWithRect:NSMakeRect(inset, inset, size.width - 2*inset, size.height - 2*inset) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingTruncatesLastVisibleLine];
		return YES;
	}], nil);
}
@end
