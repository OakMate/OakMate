#import "../src/render.h"
#import <QuickLookUI/QuickLookUI.h>

@interface TMQLPreviewProvider : QLPreviewProvider <QLPreviewingController>
@end

@implementation TMQLPreviewProvider
- (void)providePreviewForFileRequest:(QLFilePreviewRequest*)request completionHandler:(void(^)(QLPreviewReply*, NSError*))handler
{
	NSURL* url = request.fileURL;
	handler([[QLPreviewReply alloc] initWithDataOfContentType:UTTypeRTF contentSize:CGSizeZero dataCreationBlock:^NSData*(QLPreviewReply* reply, NSError** error){
		NSColor* backgroundColor;
		if(NSAttributedString* str = TMQLCreatePreview(url, &backgroundColor))
		{
			return [str RTFFromRange:NSMakeRange(0, str.length) documentAttributes:@{
				NSDocumentTypeDocumentAttribute:    NSRTFTextDocumentType,
				NSBackgroundColorDocumentAttribute: backgroundColor ?: NSColor.textBackgroundColor,
			}];
		}

		// Unable to highlight the file (e.g. theme not found), show it as plain text
		reply.stringEncoding = NSUTF8StringEncoding;
		return [[NSString stringWithContentsOfURL:url usedEncoding:nil error:nil] ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
	}], nil);
}
@end
