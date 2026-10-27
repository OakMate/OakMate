#include "resource.h"
#include "path.h"
#include <cf/cf.h>
#include <sys/xattr.h>
#include <libkern/OSByteOrder.h>

namespace path
{
	bool is_text_clipping (std::string const& path)
	{
		bool res = false;
		if(extension(path) == "textClipping")
		{
			res = true;
		}
		else
		{
			// The file type is stored (big-endian) in the first four bytes of the Finder info
			uint8_t finderInfo[32];
			if(getxattr(path.c_str(), XATTR_FINDERINFO_NAME, finderInfo, sizeof(finderInfo), 0, 0) >= 4)
				res = OSReadBigInt32(finderInfo, 0) == kClippingTextType;
		}
		return res;
	}

	std::string resource (std::string const& path, ResType theType, ResID theID)
	{
		std::string res = NULL_STR;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		FSRef fsref;
		if(noErr != FSPathMakeRefWithOptions((UInt8 const*)path.c_str(), kFSPathMakeRefDoNotFollowLeafSymlink, &fsref, NULL))
		{
			if(ResFileRefNum ref = FSOpenResFile(&fsref, fsRdPerm))
			{
				if(Handle handle = Get1Resource(theType, theID))
				{
					HLock(handle);
					res = std::string(*handle, *handle + GetHandleSize(handle));
					HUnlock(handle);
					ReleaseResource(handle);
				}
				CloseResFile(ref);
			}
		}
#pragma clang diagnostic pop
		return res;
	}

} /* path */
