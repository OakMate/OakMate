#import <WebKit/WebKit.h>

// Adds TextMate’s find and “view source” actions to WKWebView
@interface HOWebView : WKWebView
- (IBAction)findNext:(id)sender;
- (IBAction)findPrevious:(id)sender;
- (IBAction)copySelectionToFindPboard:(id)sender;
- (IBAction)copySelectionToReplacePboard:(id)sender;
- (IBAction)viewSource:(id)sender;
@end
