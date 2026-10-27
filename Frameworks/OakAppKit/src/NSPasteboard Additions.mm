#import "NSPasteboard Additions.h"

@implementation NSPasteboard (OakFileURLs)
- (NSArray<NSString*>*)tmFilePaths
{
	NSArray<NSURL*>* urls = [self readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
	return urls.count ? [urls valueForKey:@"path"] : nil;
}
@end
