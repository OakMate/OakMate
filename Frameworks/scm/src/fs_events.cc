#include "fs_events.h"

namespace scm
{
	watcher_t::watcher_t (std::string const& path, std::function<void(std::set<std::string> const&)> const& callback)
	{
		auto callbackCopy = callback;
		_stream = std::make_shared<fs::event_stream_t>(std::vector<std::string>{ path }, ^(std::vector<fs::event_t> const& events){
			std::set<std::string> changedPaths;
			for(auto const& event : events)
				changedPaths.insert(event.path);
			callbackCopy(changedPaths);
		});

		if(!*_stream)
			os_log_error(OS_LOG_DEFAULT, "Can’t observe ‘%{public}s’", path.c_str());
	}
}
