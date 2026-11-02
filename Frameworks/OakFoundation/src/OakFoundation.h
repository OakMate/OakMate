#ifndef OAKFOUNDATION_H_816ED92F
#define OAKFOUNDATION_H_816ED92F

#ifdef __cplusplus
std::string OakMoveToTrash (std::string const& path);
#endif

#ifdef __OBJC__
@protocol OakUserDefaultsObserver <NSObject>
- (void)userDefaultsDidChange:(NSNotification*)aNotification;
@end

BOOL OakIsEmptyString (NSString* str);
BOOL OakNotEmptyString (NSString* str);
void OakObserveUserDefaults (id <OakUserDefaultsObserver> obj);
#endif

// Runs ‘block’ on the main thread from the run loop. Use it instead of dispatch_async(dispatch_get_main_queue(), …) for work that can show a modal window or run a nested event loop: while a block from the main dispatch queue runs, the main queue is not serviced, so everything that depends on it, like scrolling, stalls until the modal window is closed.
void OakRunOnMainRunLoop (void(^block)());

#endif /* end of include guard: OAKFOUNDATION_H_816ED92F */
