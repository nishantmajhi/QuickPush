/*
 * Quick Push - which script a menu click runs, and the command line that
 * runs it.
 *
 * Split out of quickpush_shellext.c so it can be tested without COM, a
 * registry, or Explorer: tests/cmdline_test.c links this file directly.
 * Everything here is pure - it reads no global state and starts no process.
 */

#ifndef QUICKPUSH_CMDLINE_H
#define QUICKPUSH_CMDLINE_H

#include <stddef.h>

#ifdef _WIN32
#include <windows.h>
#else
typedef int BOOL;
#define TRUE 1
#define FALSE 0
typedef unsigned int UINT;
#endif

#include <wchar.h>

/* Menu positions inside the Quick Push submenu. The same two offsets mean
 * different things depending on whether the folder is already a repository,
 * which is why resolving them needs both pieces of information. */
#define QP_ITEM_A 0u
#define QP_ITEM_B 1u

typedef enum {
    QP_SCRIPT_NONE = 0,
    QP_SCRIPT_COMMIT_PUSH,
    QP_SCRIPT_GIT_STATUS,
    QP_SCRIPT_INIT_PUBLIC,
    QP_SCRIPT_INIT_PRIVATE
} QuickPushScript;

/* QP_SCRIPT_NONE for any offset the submenu does not define. */
QuickPushScript QuickPushResolveCommand(BOOL isRepo, UINT idCmd);

/* File name only, no directory. NULL for QP_SCRIPT_NONE. */
const wchar_t *QuickPushScriptFile(QuickPushScript script);

/* Extra arguments the script needs, or L"" when it needs none. */
const wchar_t *QuickPushScriptArgs(QuickPushScript script);

/*
 * Writes the full powershell.exe command line for $script into $out.
 *
 * Returns FALSE - leaving $out as an empty string - if anything is missing,
 * if the result would not fit, or if either path contains a double quote.
 * Windows already forbids " in file names, so that last check can never fire
 * through Explorer; it is here so that the quoting below stays safe if a
 * future caller passes a path from somewhere else.
 */
BOOL QuickPushBuildCommandLine(const wchar_t *installDir,
                               const wchar_t *folderPath,
                               QuickPushScript script,
                               wchar_t *out,
                               size_t outCount);

#endif /* QUICKPUSH_CMDLINE_H */
