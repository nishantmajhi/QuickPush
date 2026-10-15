/*
 * Tests for the shell extension's command-line construction.
 *
 *   gcc -std=c99 -Wall -o cmdline_test.exe cmdline_test.c \
 *       ../shell-extension/quickpush_cmdline.c
 *
 * tests/run.ps1 builds and runs this automatically when a gcc is available,
 * and reads the "ok"/"FAIL" lines below into its own tally. It links only the
 * extracted module - no COM, no Explorer, so it runs anywhere gcc does.
 */

#include <stdio.h>
#include <string.h>
#include <wchar.h>

#include "../shell-extension/quickpush_cmdline.h"

static int failures = 0;

static void ok(const char *name) {
    printf("ok   %s\n", name);
}

static void fail(const char *name, const wchar_t *expected, const wchar_t *actual) {
    printf("FAIL %s\n", name);
    printf("       expected: %ls\n", expected ? expected : L"<null>");
    printf("       actual:   %ls\n", actual ? actual : L"<null>");
    failures++;
}

static void expect_wstr(const char *name, const wchar_t *expected, const wchar_t *actual) {
    if (actual && wcscmp(expected, actual) == 0) ok(name);
    else fail(name, expected, actual);
}

static void expect_int(const char *name, int expected, int actual) {
    if (expected == actual) {
        ok(name);
    } else {
        printf("FAIL %s\n", name);
        printf("       expected: %d\n", expected);
        printf("       actual:   %d\n", actual);
        failures++;
    }
}

int main(void) {
    wchar_t buffer[1024];

    /* ---- which script a click maps to ---- */

    expect_int("repo folder, first item is Commit & Push",
               QP_SCRIPT_COMMIT_PUSH, QuickPushResolveCommand(TRUE, QP_ITEM_A));
    expect_int("repo folder, second item is Git Status",
               QP_SCRIPT_GIT_STATUS, QuickPushResolveCommand(TRUE, QP_ITEM_B));
    expect_int("plain folder, first item initialises a public repo",
               QP_SCRIPT_INIT_PUBLIC, QuickPushResolveCommand(FALSE, QP_ITEM_A));
    expect_int("plain folder, second item initialises a private repo",
               QP_SCRIPT_INIT_PRIVATE, QuickPushResolveCommand(FALSE, QP_ITEM_B));
    expect_int("an offset the submenu never inserted resolves to nothing",
               QP_SCRIPT_NONE, QuickPushResolveCommand(TRUE, 2));
    expect_int("the container item's own id is not invokable",
               QP_SCRIPT_NONE, QuickPushResolveCommand(FALSE, 7));

    expect_wstr("public and private init share one script",
                QuickPushScriptFile(QP_SCRIPT_INIT_PUBLIC),
                QuickPushScriptFile(QP_SCRIPT_INIT_PRIVATE));
    expect_wstr("but not one visibility",
                L"-Visibility private", QuickPushScriptArgs(QP_SCRIPT_INIT_PRIVATE));
    expect_wstr("commit-push takes no extra arguments",
                L"", QuickPushScriptArgs(QP_SCRIPT_COMMIT_PUSH));

    /* ---- the command line itself ---- */

    expect_int("commit-push line builds", TRUE,
               QuickPushBuildCommandLine(L"C:\\Users\\a\\AppData\\Local\\QuickPush",
                                         L"D:\\code\\project",
                                         QP_SCRIPT_COMMIT_PUSH, buffer, 1024));
    expect_wstr("commit-push line is quoted and complete",
                L"powershell.exe -NoLogo -ExecutionPolicy Bypass -File "
                L"\"C:\\Users\\a\\AppData\\Local\\QuickPush\\commit-push.ps1\" "
                L"-Path \"D:\\code\\project\"",
                buffer);

    expect_int("init line builds", TRUE,
               QuickPushBuildCommandLine(L"C:\\qp", L"D:\\new", QP_SCRIPT_INIT_PUBLIC, buffer, 1024));
    expect_wstr("init line carries the visibility argument outside the quotes",
                L"powershell.exe -NoLogo -ExecutionPolicy Bypass -File "
                L"\"C:\\qp\\init-repo.ps1\" -Path \"D:\\new\" -Visibility public",
                buffer);

    /* A folder whose name is not ASCII is the whole reason this is built as
     * UTF-16 and launched with CreateProcessW. Through CreateProcessA these
     * characters became question marks and the script opened the wrong path,
     * or none. */
    expect_int("non-ASCII folder path builds", TRUE,
               QuickPushBuildCommandLine(L"C:\\qp", L"D:\\\u0915\u094b\u0921\\\u9805\u76ee",
                                         QP_SCRIPT_GIT_STATUS, buffer, 1024));
    expect_wstr("non-ASCII folder path survives intact",
                L"powershell.exe -NoLogo -ExecutionPolicy Bypass -File "
                L"\"C:\\qp\\git-status.ps1\" -Path \"D:\\\u0915\u094b\u0921\\\u9805\u76ee\"",
                buffer);

    expect_int("a folder name with spaces still builds", TRUE,
               QuickPushBuildCommandLine(L"C:\\qp", L"D:\\My Code\\a b",
                                         QP_SCRIPT_COMMIT_PUSH, buffer, 1024));
    expect_wstr("spaces are inside the quotes",
                L"powershell.exe -NoLogo -ExecutionPolicy Bypass -File "
                L"\"C:\\qp\\commit-push.ps1\" -Path \"D:\\My Code\\a b\"",
                buffer);

    /* ---- refusals ---- */

    expect_int("an unresolved command builds nothing", FALSE,
               QuickPushBuildCommandLine(L"C:\\qp", L"D:\\x", QP_SCRIPT_NONE, buffer, 1024));
    expect_wstr("and leaves the buffer empty rather than stale", L"", buffer);

    expect_int("an empty folder path is refused", FALSE,
               QuickPushBuildCommandLine(L"C:\\qp", L"", QP_SCRIPT_COMMIT_PUSH, buffer, 1024));
    expect_int("an empty install directory is refused", FALSE,
               QuickPushBuildCommandLine(L"", L"D:\\x", QP_SCRIPT_COMMIT_PUSH, buffer, 1024));

    /* Windows forbids " in a file name, so Explorer cannot produce this. The
     * check is what keeps that from being an unwritten assumption. */
    expect_int("a quote in the path is refused rather than injected", FALSE,
               QuickPushBuildCommandLine(L"C:\\qp", L"D:\\x\" -Path \"C:\\Windows",
                                         QP_SCRIPT_COMMIT_PUSH, buffer, 1024));
    expect_wstr("and nothing is left to launch", L"", buffer);

    expect_int("a line that would not fit is refused, not truncated", FALSE,
               QuickPushBuildCommandLine(L"C:\\qp", L"D:\\x", QP_SCRIPT_COMMIT_PUSH, buffer, 40));
    expect_wstr("a truncated line never reaches CreateProcessW", L"", buffer);

    if (failures > 0) {
        printf("%d command-line test(s) failed\n", failures);
        return 1;
    }
    return 0;
}
