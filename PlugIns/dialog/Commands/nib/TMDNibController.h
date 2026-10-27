//
//  TMDNibController.h
//  Dialog2
//

@interface TMDNibController : NSObject <NSWindowDelegate>
+ (TMDNibController*)controllerForToken:(NSString*)aToken;
+ (NSArray*)controllers;

@property (nonatomic, readonly) NSString* token;
@property (nonatomic) NSWindow* window;

// Return results the way the Dialog 1 tool did and optionally dispose after
// returning. See Commands/nib/dialog1.mm.
@property (nonatomic) BOOL dialog1Results;
@property (nonatomic) BOOL dialog1Async;
@property (nonatomic) BOOL tearDownAfterReturn;
- (id)initWithNibPath:(NSString*)aPath;
- (void)showWindowAndCenter:(BOOL)shouldCenter;

- (void)addClientFileHandle:(NSFileHandle*)aFileHandle modal:(BOOL)flag;
- (void)updateParametersWith:(id)plist;
- (void)tearDown;
@end
