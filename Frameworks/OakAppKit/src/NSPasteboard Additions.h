@interface NSPasteboard (OakFileURLs)
@property (nonatomic, readonly) NSArray<NSString*>* tmFilePaths; // Paths of file URLs on the pasteboard, nil if there are none
@end
