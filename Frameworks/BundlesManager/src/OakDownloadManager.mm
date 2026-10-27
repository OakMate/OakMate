#import "OakDownloadManager.h"
#import <oak/misc.h>

// Downloads are only allowed over HTTPS, which authenticates the server
static NSError* InsecureURLError (NSURL* url)
{
	if([url.scheme isEqualToString:@"https"])
		return nil;
	return [NSError errorWithDomain:@"OakDownloadManager" code:0 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Refusing to download %@ without HTTPS.", url.absoluteString] }];
}

// ==========================
// = OakDownloadArchiveTask =
// ==========================

@interface OakDownloadArchiveTask : NSObject <NSProgressReporting, NSURLSessionDataDelegate>
{
	void(^_completionHandler)(NSURL* extractedArchiveURL, NSError* error);

	NSURL*                              _fileURLToReplace;
	NSURL*                              _temporaryFileURL;

	NSTask*                             _extractorTask;
	NSFileHandle*                       _extractorFileHandle;
	dispatch_group_t                    _extractorDispatchGroup;
	NSError*                            _extractorError;

	NSDate*                             _sampleStartDate;
	int64_t                             _sampleCountOfBytesReceived;
}
@property (nonatomic) NSProgress* progress;
@property (nonatomic) NSData* extractorTaskOutputData;
@property (nonatomic) NSData* extractorTaskErrorData;
@end

@implementation OakDownloadArchiveTask
- (instancetype)initWithURL:(NSURL*)url forReplacingURL:(NSURL*)localURL completionHandler:(void(^)(NSURL* extractedArchiveURL, NSError* error))completionHandler
{
	if(self = [super init])
	{
		_fileURLToReplace       = localURL;
		_completionHandler      = completionHandler;
		_progress               = [NSProgress discreteProgressWithTotalUnitCount:-1];
		_extractorDispatchGroup = dispatch_group_create();

		_progress.kind = NSProgressKindFile;
		_progress.fileOperationKind = NSProgressFileOperationKindDownloading;
		_progress.localizedDescription = [NSString stringWithFormat:@"Downloading %@…", url.lastPathComponent];

		if(NSError* error = InsecureURLError(url))
		{
			dispatch_async(dispatch_get_main_queue(), ^{
				completionHandler(nil, error);
			});
			return self;
		}

		NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60];
		[request setValue:OakDownloadManager.sharedInstance.userAgentString forHTTPHeaderField:@"User-Agent"];

		NSURLSession* session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:self delegateQueue:NSOperationQueue.mainQueue];
		[[session dataTaskWithRequest:request] resume];
		[session finishTasksAndInvalidate];
	}
	return self;
}

- (void)dealloc
{
	NSError* error;
	if(_temporaryFileURL && ![NSFileManager.defaultManager removeItemAtURL:_temporaryFileURL error:&error])
		os_log_error(OS_LOG_DEFAULT, "Unable to remove %{public}@: %{public}@", _temporaryFileURL.path, error.localizedDescription);
}

- (NSFileHandle*)extractorFileHandle
{
	if(!_extractorFileHandle)
	{
		NSError* error;
		if(!(_temporaryFileURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:_fileURLToReplace create:YES error:&error]))
		{
			os_log_error(OS_LOG_DEFAULT, "Failed to obtain NSItemReplacementDirectory: %{public}@", error.localizedDescription);
			_extractorError = error;
			return nil;
		}

		NSPipe* inputPipe  = [NSPipe pipe];
		NSPipe* outputPipe = [NSPipe pipe];
		NSPipe* errorPipe  = [NSPipe pipe];

		_extractorTask = [[NSTask alloc] init];
		_extractorTask.launchPath     = @"/usr/bin/tar";
		_extractorTask.arguments      = @[ @"-jxmkC", _temporaryFileURL.filePathURL.path, @"--strip-components", @"1", @"--disable-copyfile", @"--exclude", @"._*" ];
		_extractorTask.standardInput  = inputPipe;
		_extractorTask.standardOutput = outputPipe;
		_extractorTask.standardError  = errorPipe;

		dispatch_group_async(_extractorDispatchGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			self.extractorTaskOutputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
			[outputPipe.fileHandleForReading closeFile];
		});

		dispatch_group_async(_extractorDispatchGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			self.extractorTaskErrorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
			[errorPipe.fileHandleForReading closeFile];
		});

		dispatch_group_t group = _extractorDispatchGroup; // Avoid capturing ‘self’ in terminationHandler

		dispatch_group_enter(group);
		_extractorTask.terminationHandler = ^(NSTask* theTask){
			dispatch_group_leave(group);
		};

		if(![_extractorTask launchAndReturnError:&error])
		{
			os_log_error(OS_LOG_DEFAULT, "Failed to launch tar: %{public}@", error.localizedDescription);

			dispatch_group_leave(_extractorDispatchGroup); // Completion handler will never be called
			[outputPipe.fileHandleForWriting closeFile];
			[errorPipe.fileHandleForWriting closeFile];

			_extractorTask  = nil;
			_extractorError = error;

			return nil;
		}
		_extractorFileHandle = inputPipe.fileHandleForWriting;
	}
	return _extractorFileHandle;
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request completionHandler:(void(^)(NSURLRequest*))completionHandler
{
	completionHandler(InsecureURLError(request.URL) ? nil : request);
}

- (void)URLSession:(NSURLSession*)session dataTask:(NSURLSessionDataTask*)dataTask didReceiveResponse:(NSURLResponse*)response completionHandler:(void(^)(NSURLSessionResponseDisposition disposition))completionHandler
{
	NSInteger statusCode = ((NSHTTPURLResponse*)response).statusCode;
	if(statusCode != 200)
		_extractorError = [NSError errorWithDomain:@"OakDownloadManager" code:0 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Server returned %ld for %@", statusCode, response.URL.absoluteString] }];
	completionHandler(statusCode == 200 ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession*)session dataTask:(NSURLSessionDataTask*)dataTask didReceiveData:(NSData*)data
{
	NSFileHandle* fileHandle = self.extractorFileHandle;
	if(fileHandle && !_progress.isCancelled)
	{
		[fileHandle writeData:data];

		if(dataTask.countOfBytesExpectedToReceive != NSURLSessionTransferSizeUnknown)
		{
			if(!_sampleStartDate)
			{
				_sampleStartDate = [NSDate date];
			}
			else
			{
				if(int64_t bytesLeft = dataTask.countOfBytesExpectedToReceive - dataTask.countOfBytesReceived)
				{
					NSTimeInterval secondsSampled = -_sampleStartDate.timeIntervalSinceNow;
					if(secondsSampled > 0.9)
					{
						int64_t bytesReceivedSinceLastSample = dataTask.countOfBytesReceived - _sampleCountOfBytesReceived;
						[_progress setUserInfoObject:@(ceil(bytesLeft * secondsSampled / bytesReceivedSinceLastSample)) forKey:NSProgressEstimatedTimeRemainingKey];

						_sampleStartDate            = [NSDate date];
						_sampleCountOfBytesReceived = dataTask.countOfBytesReceived;
					}
				}
				else
				{
					[_progress setUserInfoObject:nil forKey:NSProgressEstimatedTimeRemainingKey];
				}
			}
		}

		_progress.totalUnitCount     = dataTask.countOfBytesExpectedToReceive;
		_progress.completedUnitCount = dataTask.countOfBytesReceived;
	}
	else
	{
		[dataTask cancel];
	}
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)dataTask didCompleteWithError:(NSError*)downloadError
{
	[_extractorFileHandle closeFile];
	_progress.totalUnitCount = dataTask.countOfBytesReceived;

	if(NSError* error = _extractorError ?: (_extractorTask ? downloadError : [NSError errorWithDomain:@"OakDownloadManager" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"Unable to launch tar." }]))
	{
		os_log_error(OS_LOG_DEFAULT, "Failed to download %{public}@: %{public}@", dataTask.originalRequest.URL, error.localizedDescription);
		_completionHandler(nil, error);
	}
	else
	{
		dispatch_group_notify(_extractorDispatchGroup, dispatch_get_main_queue(), ^{
			if(_extractorTask.terminationStatus == 0)
			{
				NSURL* url = _temporaryFileURL;
				_temporaryFileURL = nil;
				_completionHandler(url, nil);
			}
			else
			{
				NSString* errorString  = _extractorTaskErrorData.length  ? [[NSString alloc] initWithData:_extractorTaskErrorData  encoding:NSUTF8StringEncoding] : nil;
				NSString* outputString = _extractorTaskOutputData.length ? [[NSString alloc] initWithData:_extractorTaskOutputData encoding:NSUTF8StringEncoding] : nil;

				os_log_error(OS_LOG_DEFAULT, "Abnormal exit from tar: %d", _extractorTask.terminationStatus);
				if(errorString)
					os_log_error(OS_LOG_DEFAULT, "%{public}@", errorString);
				if(outputString)
					os_log_error(OS_LOG_DEFAULT, "%{public}@", outputString);

				NSString* description = errorString ?: outputString ?: [NSString stringWithFormat:@"Abnormal exit from tar: %d", _extractorTask.terminationStatus];
				description = [description stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
				description = [description stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
				_completionHandler(nil, [NSError errorWithDomain:@"OakDownloadManager" code:0 userInfo:@{ NSLocalizedDescriptionKey: description }]);
			}
		});
	}
}
@end

// ======================
// = OakDownloadManager =
// ======================

@interface OakDownloadManager ()
{
	NSString* _userAgentString;
}
@end

@implementation OakDownloadManager
+ (instancetype)sharedInstance
{
	static OakDownloadManager* sharedInstance = [self new];
	return sharedInstance;
}

- (NSString*)userAgentString
{
	if(!_userAgentString)
	{
		NSString* appName    = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
		NSString* appVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];

		NSOperatingSystemVersion osVersion = NSProcessInfo.processInfo.operatingSystemVersion;
		_userAgentString = [NSString stringWithFormat:@"%@/%@ macOS/%ld.%ld.%ld", appName, appVersion, osVersion.majorVersion, osVersion.minorVersion, osVersion.patchVersion];
	}
	return _userAgentString;
}

- (void)downloadFileAtURL:(NSURL*)serverURL replacingFileAtURL:(NSURL*)localFileURL completionHandler:(void(^)(BOOL wasUpdated, NSError* error))completionHandler
{
	if(NSError* error = InsecureURLError(serverURL))
		return completionHandler(NO, error);

	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:serverURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
	[request setValue:self.userAgentString forHTTPHeaderField:@"User-Agent"];

	ssize_t size = getxattr(localFileURL.fileSystemRepresentation, "org.w3.http.etag", nullptr, 0, 0, 0);
	if(size != -1)
	{
		if(NSMutableData* tempData = [NSMutableData dataWithLength:size])
		{
			getxattr(localFileURL.fileSystemRepresentation, "org.w3.http.etag", tempData.mutableBytes, tempData.length, 0, 0);
			if(NSString* entityTag = [[NSString alloc] initWithData:tempData encoding:NSUTF8StringEncoding])
			{
				[request setValue:entityTag forHTTPHeaderField:@"If-None-Match"];
				os_log(OS_LOG_DEFAULT, "GET %{public}@ using entity tag %{public}@", serverURL.absoluteString, entityTag);
			}
		}
	}

	NSURLSessionDataTask* dataTask = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error){
		BOOL wasUpdated = NO;

		NSInteger statusCode = ((NSHTTPURLResponse*)response).statusCode;
		if(error || statusCode != 200)
		{
			if(!error && statusCode != 304)
				error = [NSError errorWithDomain:@"OakDownloadManager" code:0 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Server returned %ld for %@", statusCode, serverURL.absoluteString] }];
		}
		else if([data writeToURL:localFileURL options:NSDataWritingAtomic error:&error])
		{
			wasUpdated = YES;

			if(NSString* newETag = ((NSHTTPURLResponse*)response).allHeaderFields[@"ETag"])
			{
				char const* str = newETag.UTF8String;
				if(setxattr(localFileURL.fileSystemRepresentation, "org.w3.http.etag", str, strlen(str), 0, 0) == -1)
					os_log_error(OS_LOG_DEFAULT, "setxattr(%{public}@): %{darwin.errno}d", localFileURL.path, errno);
			}
			else
			{
				os_log_error(OS_LOG_DEFAULT, "No ETag: %{public}@", serverURL.absoluteString);
			}
		}

		completionHandler(wasUpdated, error);
	}];
	[dataTask resume];
}

- (id <NSProgressReporting>)downloadArchiveAtURL:(NSURL*)serverURL forReplacingURL:(nullable NSURL*)localURL completionHandler:(void(^)(NSURL* extractedArchiveURL, NSError* error))completionHandler
{
	return [[OakDownloadArchiveTask alloc] initWithURL:serverURL forReplacingURL:localURL completionHandler:completionHandler];
}
@end
