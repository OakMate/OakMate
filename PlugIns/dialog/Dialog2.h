// The plug-in listens on a Unix domain socket whose path is in DIALOG_SOCKET.
//
// tm_dialog2 sends a property list with its arguments, environment, and
// working directory, together with three pipes for standard input, output,
// and error. The command is done when OakMate closes the output pipes, after
// which it sends the exit status as a decimal string and closes the socket.

static NSString* const kDialogSocketEnvironmentVariable = @"DIALOG_SOCKET";

static NSString* const kDialogArgumentsKey        = @"arguments";
static NSString* const kDialogEnvironmentKey      = @"environment";
static NSString* const kDialogWorkingDirectoryKey = @"cwd";
