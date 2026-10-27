window.addEventListener("error", function(event) {
	webkit.messageHandlers.oakmate.postMessage({
		command: "log",
		payload: {
			level:    "error",
			message:  event.message,
			filename: event.filename,
			lineno:   event.lineno,
			colno:    event.colno
		}
	});
});

let OakMate = {
	log(str) {
		webkit.messageHandlers.oakmate.postMessage({
			command: "log",
			payload: {
				message: str
			}
		});
	},
	version:	  null,
	copyright: null
};
