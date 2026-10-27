#import <bundles/item.h>

@interface BundlesManager : NSObject
@property (class, readonly) BundlesManager* sharedInstance;

- (void)loadBundlesIndex;
- (void)installBundleItemsAtPaths:(NSArray*)somePaths;
- (BOOL)findBundleForInstall:(bundles::item_ptr*)res;
- (void)reloadPath:(NSString*)aPath;
@end
