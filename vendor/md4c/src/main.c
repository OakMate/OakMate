// md2html: Convert Markdown read from stdin to HTML written to stdout.
// Used by bin/gen_html when building TextMate’s About and Help pages.

#include "md4c-html.h"
#include <stdio.h>
#include <stdlib.h>

static void write_output (MD_CHAR const* text, MD_SIZE size, void* userdata)
{
	fwrite(text, 1, size, (FILE*)userdata);
}

int main (int argc, char const* argv[])
{
	size_t len = 0, capacity = 64*1024;
	char* buf = malloc(capacity);
	for(size_t n; buf && (n = fread(buf + len, 1, capacity - len, stdin)) > 0; )
	{
		if((len += n) == capacity)
			buf = realloc(buf, capacity *= 2);
	}

	if(!buf || ferror(stdin))
	{
		fprintf(stderr, "md2html: error reading input\n");
		return EXIT_FAILURE;
	}

	int rc = md_html(buf, (MD_SIZE)len, &write_output, stdout, MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH, 0);
	free(buf);

	if(rc != 0 || fflush(stdout) != 0)
	{
		fprintf(stderr, "md2html: conversion failed\n");
		return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
}
