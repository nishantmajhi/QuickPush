#include "quickpush_cmdline.h"

/*
 * Appends $text at $*pos, advancing it. Returns FALSE and stops writing the
 * moment the result would not fit, so a truncated command line can never be
 * launched - a half-written -Path argument would point somewhere else.
 */
static BOOL AppendW(wchar_t *out, size_t outCount, size_t *pos, const wchar_t *text) {
    size_t i = 0;
    if (!out || !text || outCount == 0) return FALSE;
    while (text[i] != L'\0') {
        if (*pos + 1 >= outCount) return FALSE;   /* +1 keeps room for the terminator */
        out[*pos] = text[i];
        (*pos)++;
        i++;
    }
    out[*pos] = L'\0';
    return TRUE;
}

static BOOL ContainsQuote(const wchar_t *text) {
    size_t i;
    for (i = 0; text[i] != L'\0'; i++) {
        if (text[i] == L'"') return TRUE;
    }
    return FALSE;
}

QuickPushScript QuickPushResolveCommand(BOOL isRepo, UINT idCmd) {
    if (isRepo) {
        if (idCmd == QP_ITEM_A) return QP_SCRIPT_COMMIT_PUSH;
        if (idCmd == QP_ITEM_B) return QP_SCRIPT_GIT_STATUS;
        return QP_SCRIPT_NONE;
    }
    if (idCmd == QP_ITEM_A) return QP_SCRIPT_INIT_PUBLIC;
    if (idCmd == QP_ITEM_B) return QP_SCRIPT_INIT_PRIVATE;
    return QP_SCRIPT_NONE;
}

const wchar_t *QuickPushScriptFile(QuickPushScript script) {
    switch (script) {
        case QP_SCRIPT_COMMIT_PUSH:  return L"commit-push.ps1";
        case QP_SCRIPT_GIT_STATUS:   return L"git-status.ps1";
        case QP_SCRIPT_INIT_PUBLIC:  return L"init-repo.ps1";
        case QP_SCRIPT_INIT_PRIVATE: return L"init-repo.ps1";
        default:                     return NULL;
    }
}

const wchar_t *QuickPushScriptArgs(QuickPushScript script) {
    switch (script) {
        case QP_SCRIPT_INIT_PUBLIC:  return L"-Visibility public";
        case QP_SCRIPT_INIT_PRIVATE: return L"-Visibility private";
        default:                     return L"";
    }
}

BOOL QuickPushBuildCommandLine(const wchar_t *installDir,
                               const wchar_t *folderPath,
                               QuickPushScript script,
                               wchar_t *out,
                               size_t outCount) {
    const wchar_t *file;
    const wchar_t *args;
    size_t pos = 0;

    if (!out || outCount == 0) return FALSE;
    out[0] = L'\0';

    if (!installDir || !folderPath) return FALSE;
    if (installDir[0] == L'\0' || folderPath[0] == L'\0') return FALSE;
    if (ContainsQuote(installDir) || ContainsQuote(folderPath)) return FALSE;

    file = QuickPushScriptFile(script);
    if (!file) return FALSE;
    args = QuickPushScriptArgs(script);

    if (!AppendW(out, outCount, &pos, L"powershell.exe -NoLogo -ExecutionPolicy Bypass -File \"") ||
        !AppendW(out, outCount, &pos, installDir) ||
        !AppendW(out, outCount, &pos, L"\\") ||
        !AppendW(out, outCount, &pos, file) ||
        !AppendW(out, outCount, &pos, L"\" -Path \"") ||
        !AppendW(out, outCount, &pos, folderPath) ||
        !AppendW(out, outCount, &pos, L"\"")) {
        out[0] = L'\0';
        return FALSE;
    }

    if (args[0] != L'\0') {
        if (!AppendW(out, outCount, &pos, L" ") ||
            !AppendW(out, outCount, &pos, args)) {
            out[0] = L'\0';
            return FALSE;
        }
    }

    return TRUE;
}
