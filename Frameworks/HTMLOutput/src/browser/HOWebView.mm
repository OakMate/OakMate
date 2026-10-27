#import "HOWebView.h"
#import <OakAppKit/OakPasteboard.h>
#import <OakFoundation/OakFoundation.h>
#import <OakFoundation/OakFindProtocol.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>

@interface HOWebView () <OakFindClientProtocol>
@end

@implementation HOWebView
- (void)getSelection:(void(^)(NSString*))handler
{
	[self evaluateJavaScript:@"window.getSelection().toString()" inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id res, NSError* error){
		handler([res isKindOfClass:[NSString class]] && OakNotEmptyString(res) ? res : nil);
	}];
}

- (IBAction)copySelectionToFindPboard:(id)sender
{
	[self getSelection:^(NSString* str){
		if(str)
				[OakPasteboard.findPasteboard addEntryWithString:str];
		else	NSBeep();
	}];
}

- (IBAction)copySelectionToReplacePboard:(id)sender
{
	[self getSelection:^(NSString* str){
		if(str)
				[OakPasteboard.replacePasteboard addEntryWithString:str];
		else	NSBeep();
	}];
}

- (void)findString:(NSString*)aString backwards:(BOOL)backwards caseSensitive:(BOOL)caseSensitive wrap:(BOOL)wrap completionHandler:(void(^)(BOOL))handler
{
	WKFindConfiguration* config = [[WKFindConfiguration alloc] init];
	config.backwards     = backwards;
	config.caseSensitive = caseSensitive;
	config.wraps         = wrap;

	[self findString:aString withConfiguration:config completionHandler:^(WKFindResult* result){
		if(handler)
			handler(result.matchFound);
	}];
}

- (void)performFindOperation:(id <OakFindServerProtocol>)aFindServer
{
	switch(aFindServer.findOperation)
	{
		case kFindOperationFind:
		case kFindOperationFindInSelection:
		{
			NSString* findString = aFindServer.findString;
			find::options_t options = aFindServer.findOptions;
			[self findString:findString backwards:(options & find::backwards) caseSensitive:!(options & find::ignore_case) wrap:(options & find::wrap_around) completionHandler:^(BOOL didFind){
				if(didFind)
				{
					[self getSelection:^(NSString* selection){
						[aFindServer didFind:1 occurrencesOf:selection ?: findString atPosition:text::pos_t::undefined wrapped:NO];
					}];
				}
				else
				{
					[aFindServer didFind:0 occurrencesOf:findString atPosition:text::pos_t::undefined wrapped:NO];
				}
			}];
		}
		break;
	}
}

- (void)findNextOrPrevious:(BOOL)backwards
{
	OakPasteboardEntry* entry = [OakPasteboard.findPasteboard current];
	if(OakNotEmptyString(entry.string))
		[self findString:entry.string backwards:backwards caseSensitive:![NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsFindIgnoreCase] wrap:[NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsFindWrapAround] completionHandler:nil];
}

- (IBAction)findNext:(id)sender     { [self findNextOrPrevious:NO];  }
- (IBAction)findPrevious:(id)sender { [self findNextOrPrevious:YES]; }

- (IBAction)viewSource:(id)sender
{
	NSString* script = @"(document.doctype ? new XMLSerializer().serializeToString(document.doctype) + '\\n' : '') + document.documentElement.outerHTML";
	[self evaluateJavaScript:script inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id res, NSError* error){
		if(![res isKindOfClass:[NSString class]])
			return (void)NSBeep();

		NSString* name = OakNotEmptyString(self.title) ? self.title : nil;
		OakDocument* doc = [OakDocument documentWithString:res fileType:@"text.html.basic" customName:name];
		[OakDocumentController.sharedInstance showDocument:doc inProject:nil bringToFront:YES];
	}];
}
@end
