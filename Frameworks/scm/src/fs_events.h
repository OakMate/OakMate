#ifndef FS_EVENTS_H_QDH73MIO
#define FS_EVENTS_H_QDH73MIO

#include <io/fsevents.h>

namespace scm
{
	struct watcher_t
	{
		watcher_t (std::string const& path, std::function<void(std::set<std::string> const&)> const& callback);

	private:
		fs::event_stream_ptr _stream;
	};

} /* scm */

#endif /* end of include guard: FS_EVENTS_H_QDH73MIO */
