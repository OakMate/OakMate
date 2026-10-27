#import "NSImage Additions.h"

@implementation NSImage (ImageFromBundle)
+ (NSImage*)imageNamed:(NSString*)aName inSameBundleAsClass:(id)aClass
{
	if(!aName)
		return nil;

	NSBundle* bundle = [NSBundle bundleForClass:aClass];
	NSString* name   = [NSString stringWithFormat:@"%@.%@", [bundle bundleIdentifier], aName];

	static NSMutableDictionary* cache = [NSMutableDictionary new];
	if(NSImage* res = [cache objectForKey:name])
		return res;

	if(NSImage* image = [bundle imageForResource:aName])
	{
		[cache setObject:image forKey:name];
		return image;
	}

	return nil;
}
@end

@implementation NSImage (FileIcons)
+ (NSImage*)tmIconForFilenameExtension:(NSString*)anExtension
{
	UTType* type = anExtension.length ? [UTType typeWithFilenameExtension:anExtension] : nil;
	return [NSWorkspace.sharedWorkspace iconForContentType:type ?: UTTypeData];
}

+ (NSImage*)tmMissingFileIcon
{
	static NSImage* image;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		image = [[NSBundle bundleWithPath:@"/System/Library/CoreServices/CoreTypes.bundle"] imageForResource:@"UnknownFSObjectIcon"];
		if(!image)
			image = [NSWorkspace.sharedWorkspace iconForContentType:UTTypeData];
	});
	return image;
}
@end
