//
//  CLIProxy.h
//  Dialog2
//
//  Created by Ciaran Walsh on 16/02/2008.
//

@interface CLIProxy : NSObject
@property (nonatomic, readonly) NSFileHandle* inputHandle;
@property (nonatomic, readonly) NSFileHandle* outputHandle;
@property (nonatomic, readonly) NSFileHandle* errorHandle;
@property (nonatomic, readonly) NSDictionary* parameters;
@property (nonatomic, readonly) NSDictionary* environment;
@property (nonatomic, readonly) NSString* workingDirectory;
@property (nonatomic) int exitStatus; // Sent to the client when the proxy is released

// Takes ownership of the file descriptors and the connection
- (instancetype)initWithOptions:(NSDictionary*)options inputFileDescriptor:(int)inputFd outputFileDescriptor:(int)outputFd errorFileDescriptor:(int)errorFd connection:(int)connection;

- (void)writeStringToOutput:(NSString*)aString;
- (void)writeStringToError:(NSString*)aString;
- (id)readPropertyListFromInput;

- (NSString*)argumentAtIndex:(NSUInteger)index;
- (NSUInteger)numberOfArguments;
@end
