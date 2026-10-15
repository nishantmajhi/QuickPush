/*
 * Quick Push - Explorer shell extension
 *
 * Registers a cascading "Quick Push" context menu item on folder
 * backgrounds and folder items. The submenu contents are computed live,
 * every time the menu is opened, based on whether the folder already has
 * a .git subfolder:
 *
 *   .git exists      -> "Commit && Push", "Git Status"
 *   .git missing      -> "Init Public Repo", "Init Private Repo"
 *
 * This is what a plain registry-verb menu cannot do (registry verbs are
 * static); a real IContextMenu COM handler is required, the same
 * mechanism tools like WinRAR/7-Zip/TortoiseGit use for their cascading,
 * icon-bearing menus.
 *
 * Paths are UTF-16 end to end. They used to be ANSI, which meant a folder
 * whose name was not representable in the system codepage - Devanagari,
 * accented Latin, CJK - reached the script as question marks and it opened
 * the wrong folder, or none. The command line itself is built by
 * quickpush_cmdline.c, which tests/cmdline_test.c covers.
 *
 * Build: see README.md for exact mingw-w64 / MSVC commands.
 * Not tested on a live Windows install - test in a VM before trusting it.
 */

#define COBJMACROS
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <objbase.h>
#include <initguid.h>
#include "resource.h"
#include "quickpush_cmdline.h"

#ifdef _MSC_VER
#pragma comment(lib, "shlwapi")
#pragma comment(lib, "ole32")
#pragma comment(lib, "uuid")
#endif

/* ---- CLSID for this handler (do not reuse for other projects) ---- */
/* 9b29e102-0e3f-4fa0-a659-42e76281100f */
DEFINE_GUID(CLSID_QuickPushMenu, 0x9b29e102, 0x0e3f, 0x4fa0,
            0xa6, 0x59, 0x42, 0xe7, 0x62, 0x81, 0x10, 0x0f);

static const wchar_t *CLSID_STRW = L"{9b29e102-0e3f-4fa0-a659-42e76281100f}";

static HINSTANCE g_hModule = NULL;
static LONG g_cDllRef = 0;

/* =====================  helpers  ===================== */

static void GetInstallDir(wchar_t *out, int outCount) {
    wchar_t localAppData[MAX_PATH];
    if (SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, 0, localAppData) != S_OK) {
        localAppData[0] = 0;
    }
    wnsprintfW(out, outCount, L"%s\\QuickPush", localAppData);
}

static BOOL PathHasGit(const wchar_t *folderPath) {
    wchar_t gitPath[MAX_PATH * 2];
    wnsprintfW(gitPath, MAX_PATH * 2, L"%s\\.git", folderPath);
    DWORD attrs = GetFileAttributesW(gitPath);
    return (attrs != INVALID_FILE_ATTRIBUTES);
}

/* Converts an HICON to a 32bpp HBITMAP suitable for MENUITEMINFO.hbmpItem. */
static HBITMAP IconToMenuBitmap(HICON hIcon, int size) {
    HDC hdcScreen = GetDC(NULL);
    HDC hdcMem = CreateCompatibleDC(hdcScreen);

    BITMAPINFO bmi;
    ZeroMemory(&bmi, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = size;
    bmi.bmiHeader.biHeight = -size; /* top-down */
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void *bits = NULL;
    HBITMAP hbmp = CreateDIBSection(hdcMem, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (hbmp && bits) {
        HBITMAP hOld = (HBITMAP)SelectObject(hdcMem, hbmp);
        ZeroMemory(bits, (size_t)size * size * 4);
        DrawIconEx(hdcMem, 0, 0, hIcon, size, size, 0, NULL, DI_NORMAL);
        SelectObject(hdcMem, hOld);
    }

    DeleteDC(hdcMem);
    ReleaseDC(NULL, hdcScreen);
    return hbmp;
}

static HBITMAP GetMenuIconBitmap(void) {
    static HBITMAP s_hbmp = NULL;
    if (!s_hbmp) {
        int size = GetSystemMetrics(SM_CXSMICON);
        HICON hIcon = (HICON)LoadImageA(g_hModule, MAKEINTRESOURCEA(IDI_QUICKPUSH),
                                         IMAGE_ICON, size, size, LR_DEFAULTCOLOR);
        if (hIcon) {
            s_hbmp = IconToMenuBitmap(hIcon, size);
            DestroyIcon(hIcon);
        }
    }
    return s_hbmp;
}

/* =====================  CQuickPushMenu object  ===================== */

typedef struct {
    IShellExtInit sei;   /* must be first member */
    IContextMenu  cm;
    LONG ref;
    wchar_t folderPath[MAX_PATH * 2];
} CQuickPushMenu;

static HRESULT QI_Common(CQuickPushMenu *obj, REFIID riid, void **ppv) {
    *ppv = NULL;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IShellExtInit)) {
        *ppv = &obj->sei;
    } else if (IsEqualIID(riid, &IID_IContextMenu)) {
        *ppv = &obj->cm;
    } else {
        return E_NOINTERFACE;
    }
    IUnknown_AddRef((IUnknown *)*ppv);
    return S_OK;
}

static ULONG AddRefCommon(CQuickPushMenu *obj) {
    return InterlockedIncrement(&obj->ref);
}

static ULONG ReleaseCommon(CQuickPushMenu *obj) {
    LONG r = InterlockedDecrement(&obj->ref);
    if (r == 0) {
        InterlockedDecrement(&g_cDllRef);
        HeapFree(GetProcessHeap(), 0, obj);
    }
    return (ULONG)r;
}

/* ---- IShellExtInit vtable ---- */
static HRESULT STDMETHODCALLTYPE SEI_QueryInterface(IShellExtInit *self, REFIID riid, void **ppv) {
    return QI_Common((CQuickPushMenu *)self, riid, ppv);
}
static ULONG STDMETHODCALLTYPE SEI_AddRef(IShellExtInit *self) {
    return AddRefCommon((CQuickPushMenu *)self);
}
static ULONG STDMETHODCALLTYPE SEI_Release(IShellExtInit *self) {
    return ReleaseCommon((CQuickPushMenu *)self);
}
static HRESULT STDMETHODCALLTYPE SEI_Initialize(IShellExtInit *self, LPCITEMIDLIST pidlFolder,
                                                 IDataObject *pdtobj, HKEY hkeyProgID) {
    CQuickPushMenu *obj = (CQuickPushMenu *)self;
    obj->folderPath[0] = 0;

    if (pidlFolder) {
        /* SHGetPathFromIDListW writes at most MAX_PATH characters, so the
           buffer being larger than that is headroom, not a requirement. */
        SHGetPathFromIDListW(pidlFolder, obj->folderPath);
    }

    if (obj->folderPath[0] == 0 && pdtobj) {
        FORMATETC fe = { CF_HDROP, NULL, DVASPECT_CONTENT, -1, TYMED_HGLOBAL };
        STGMEDIUM stg;
        if (SUCCEEDED(IDataObject_GetData(pdtobj, &fe, &stg))) {
            HDROP hDrop = (HDROP)GlobalLock(stg.hGlobal);
            if (hDrop) {
                /* Character count, not byte count - DragQueryFileW counts in
                   WCHARs, and sizeof() here would be twice the real capacity. */
                DragQueryFileW(hDrop, 0, obj->folderPath,
                               (UINT)(sizeof(obj->folderPath) / sizeof(wchar_t)));
                GlobalUnlock(stg.hGlobal);
            }
            ReleaseStgMedium(&stg);
        }
    }

    return (obj->folderPath[0] != 0) ? S_OK : E_FAIL;
}

static const IShellExtInitVtbl g_SEIVtbl = {
    SEI_QueryInterface, SEI_AddRef, SEI_Release, SEI_Initialize
};

/* ---- IContextMenu vtable ---- */
static HRESULT STDMETHODCALLTYPE CM_QueryInterface(IContextMenu *self, REFIID riid, void **ppv) {
    CQuickPushMenu *obj = CONTAINING_RECORD(self, CQuickPushMenu, cm);
    return QI_Common(obj, riid, ppv);
}
static ULONG STDMETHODCALLTYPE CM_AddRef(IContextMenu *self) {
    return AddRefCommon(CONTAINING_RECORD(self, CQuickPushMenu, cm));
}
static ULONG STDMETHODCALLTYPE CM_Release(IContextMenu *self) {
    return ReleaseCommon(CONTAINING_RECORD(self, CQuickPushMenu, cm));
}

static void InsertChildItem(HMENU hMenu, UINT pos, UINT id, const wchar_t *label) {
    MENUITEMINFOW mii;
    ZeroMemory(&mii, sizeof(mii));
    mii.cbSize = sizeof(mii);
    mii.fMask = MIIM_STRING | MIIM_ID | MIIM_FTYPE;
    mii.fType = MFT_STRING;
    mii.wID = id;
    mii.dwTypeData = (LPWSTR)label;
    InsertMenuItemW(hMenu, pos, TRUE, &mii);
}

/* Command offsets are reused: 0/1 mean different things depending on whether
   the folder is a git repo. QuickPushResolveCommand in quickpush_cmdline.c is
   where that is decided, so that the mapping can be tested on its own. */

static HRESULT STDMETHODCALLTYPE CM_QueryContextMenu(IContextMenu *self, HMENU hMenu, UINT indexMenu,
                                                       UINT idCmdFirst, UINT idCmdLast, UINT uFlags) {
    CQuickPushMenu *obj = CONTAINING_RECORD(self, CQuickPushMenu, cm);

    if (uFlags & CMF_DEFAULTONLY) {
        return MAKE_HRESULT(SEVERITY_SUCCESS, FACILITY_NULL, 0);
    }

    HMENU hSubMenu = CreatePopupMenu();
    if (!hSubMenu) return E_FAIL;

    BOOL isRepo = PathHasGit(obj->folderPath);
    if (isRepo) {
        InsertChildItem(hSubMenu, 0, idCmdFirst + QP_ITEM_A, L"Commit && Push");
        InsertChildItem(hSubMenu, 1, idCmdFirst + QP_ITEM_B, L"Git Status");
    } else {
        InsertChildItem(hSubMenu, 0, idCmdFirst + QP_ITEM_A, L"Init Public Repo");
        InsertChildItem(hSubMenu, 1, idCmdFirst + QP_ITEM_B, L"Init Private Repo");
    }

    MENUITEMINFOW mii;
    ZeroMemory(&mii, sizeof(mii));
    mii.cbSize = sizeof(mii);
    mii.fMask = MIIM_STRING | MIIM_SUBMENU | MIIM_ID | MIIM_FTYPE | MIIM_BITMAP;
    mii.fType = MFT_STRING;
    mii.wID = idCmdFirst + 2; /* container item, not directly invokable */
    mii.hSubMenu = hSubMenu;
    mii.dwTypeData = (LPWSTR)L"Quick Push";
    mii.hbmpItem = GetMenuIconBitmap(); /* may be NULL if icon load failed; fine */

    InsertMenuItemW(hMenu, indexMenu, TRUE, &mii);

    /* Highest offset used was 2 (the container's own id), so 3 ids consumed. */
    return MAKE_HRESULT(SEVERITY_SUCCESS, FACILITY_NULL, 3);
}

static HRESULT STDMETHODCALLTYPE CM_InvokeCommand(IContextMenu *self, LPCMINVOKECOMMANDINFO pici) {
    CQuickPushMenu *obj = CONTAINING_RECORD(self, CQuickPushMenu, cm);

    if (HIWORD((UINT_PTR)pici->lpVerb) != 0) {
        return E_INVALIDARG; /* only id-based invocation is supported */
    }
    UINT idCmd = LOWORD((UINT_PTR)pici->lpVerb);

    QuickPushScript script = QuickPushResolveCommand(PathHasGit(obj->folderPath), idCmd);
    if (script == QP_SCRIPT_NONE) {
        return E_INVALIDARG;
    }

    wchar_t installDir[MAX_PATH];
    GetInstallDir(installDir, MAX_PATH);

    wchar_t cmdLine[MAX_PATH * 4];
    if (!QuickPushBuildCommandLine(installDir, obj->folderPath, script,
                                   cmdLine, MAX_PATH * 4)) {
        MessageBoxW(pici->hwnd,
                    L"Quick Push could not work out what to run for this folder.\n\n"
                    L"The folder path may be unusually long, or contain a character "
                    L"Windows does not normally allow in a file name.",
                    L"Quick Push", MB_OK | MB_ICONERROR);
        return E_FAIL;
    }

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    if (CreateProcessW(NULL, cmdLine, NULL, NULL, FALSE, CREATE_NEW_CONSOLE, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return S_OK;
    }

    /* The original returned the error code and nothing else. Explorer ignores
       an IContextMenu failure HRESULT, so a missing PowerShell, a policy block
       or a half-finished install made the menu item do nothing at all, with no
       way to tell that from a script that ran and exited quietly. */
    {
        DWORD err = GetLastError();
        wchar_t message[MAX_PATH * 5];
        wnsprintfW(message, MAX_PATH * 5,
                   L"Quick Push could not start PowerShell (Windows error %lu).\n\n"
                   L"Check that the scripts are installed, then re-run install.bat.\n\n%s",
                   err, cmdLine);
        MessageBoxW(pici->hwnd, message, L"Quick Push", MB_OK | MB_ICONERROR);
        return HRESULT_FROM_WIN32(err);
    }
}

static HRESULT STDMETHODCALLTYPE CM_GetCommandString(IContextMenu *self, UINT_PTR idCmd, UINT uType,
                                                       UINT *pReserved, LPSTR pszName, UINT cchMax) {
    if (uType == GCS_HELPTEXTA) {
        lstrcpynA(pszName, "Quick Push: commit/push or init a GitHub repo", (int)cchMax);
        return S_OK;
    }
    /* Explorer asks for the wide form on every version that matters; the
       original answered only the ANSI one, so the status-bar hint was blank. */
    if (uType == GCS_HELPTEXTW) {
        lstrcpynW((LPWSTR)pszName, L"Quick Push: commit/push or init a GitHub repo", (int)cchMax);
        return S_OK;
    }
    return E_NOTIMPL;
}

static const IContextMenuVtbl g_CMVtbl = {
    CM_QueryInterface, CM_AddRef, CM_Release,
    CM_QueryContextMenu, CM_InvokeCommand, CM_GetCommandString
};

static CQuickPushMenu *CreateQuickPushMenuObject(void) {
    CQuickPushMenu *obj = (CQuickPushMenu *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(CQuickPushMenu));
    if (!obj) return NULL;
    obj->sei.lpVtbl = (IShellExtInitVtbl *)&g_SEIVtbl;
    obj->cm.lpVtbl = (IContextMenuVtbl *)&g_CMVtbl;
    obj->ref = 1;
    InterlockedIncrement(&g_cDllRef);
    return obj;
}

/* =====================  IClassFactory  ===================== */

typedef struct {
    IClassFactory cf;
    LONG ref;
} CQuickPushClassFactory;

static HRESULT STDMETHODCALLTYPE CF_QueryInterface(IClassFactory *self, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IClassFactory)) {
        *ppv = self;
        IUnknown_AddRef((IUnknown *)self);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE CF_AddRef(IClassFactory *self) {
    CQuickPushClassFactory *f = (CQuickPushClassFactory *)self;
    return InterlockedIncrement(&f->ref);
}
static ULONG STDMETHODCALLTYPE CF_Release(IClassFactory *self) {
    CQuickPushClassFactory *f = (CQuickPushClassFactory *)self;
    LONG r = InterlockedDecrement(&f->ref);
    if (r == 0) HeapFree(GetProcessHeap(), 0, f);
    return (ULONG)r;
}
static HRESULT STDMETHODCALLTYPE CF_CreateInstance(IClassFactory *self, IUnknown *pUnkOuter,
                                                     REFIID riid, void **ppv) {
    *ppv = NULL;
    if (pUnkOuter) return CLASS_E_NOAGGREGATION;

    CQuickPushMenu *obj = CreateQuickPushMenuObject();
    if (!obj) return E_OUTOFMEMORY;

    HRESULT hr = QI_Common(obj, riid, ppv);
    ReleaseCommon(obj); /* drop our own initial ref; QI added the caller's ref */
    return hr;
}
static HRESULT STDMETHODCALLTYPE CF_LockServer(IClassFactory *self, BOOL fLock) {
    if (fLock) InterlockedIncrement(&g_cDllRef);
    else InterlockedDecrement(&g_cDllRef);
    return S_OK;
}

static const IClassFactoryVtbl g_CFVtbl = {
    CF_QueryInterface, CF_AddRef, CF_Release, CF_CreateInstance, CF_LockServer
};

/* =====================  DLL exports  ===================== */

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    if (fdwReason == DLL_PROCESS_ATTACH) {
        g_hModule = hinstDLL;
        DisableThreadLibraryCalls(hinstDLL);
    }
    return TRUE;
}

HRESULT __stdcall DllGetClassObject(REFCLSID rclsid, REFIID riid, void **ppv) {
    *ppv = NULL;
    if (!IsEqualCLSID(rclsid, &CLSID_QuickPushMenu)) {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    CQuickPushClassFactory *cf = (CQuickPushClassFactory *)HeapAlloc(
        GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(CQuickPushClassFactory));
    if (!cf) return E_OUTOFMEMORY;
    cf->cf.lpVtbl = (IClassFactoryVtbl *)&g_CFVtbl;
    cf->ref = 1;

    HRESULT hr = CF_QueryInterface(&cf->cf, riid, ppv);
    CF_Release(&cf->cf);
    return hr;
}

HRESULT __stdcall DllCanUnloadNow(void) {
    return (g_cDllRef == 0) ? S_OK : S_FALSE;
}

static void RegSetStringW(HKEY root, const wchar_t *subkey, const wchar_t *valueName, const wchar_t *value) {
    HKEY hKey;
    if (RegCreateKeyExW(root, subkey, 0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL) == ERROR_SUCCESS) {
        RegSetValueExW(hKey, valueName, 0, REG_SZ, (const BYTE *)value,
                       (DWORD)((lstrlenW(value) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
    }
}

HRESULT __stdcall DllRegisterServer(void) {
    /* Wide, like everything else: the DLL lives under the user's profile, and
       an account name outside the system codepage produced a mangled
       InprocServer32 path that COM could then never load. Note the character
       count - GetModuleFileNameW counts WCHARs, not bytes. */
    wchar_t dllPath[MAX_PATH];
    if (GetModuleFileNameW(g_hModule, dllPath, MAX_PATH) == 0) {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    wchar_t keyPath[256];

    wnsprintfW(keyPath, 256, L"Software\\Classes\\CLSID\\%s", CLSID_STRW);
    RegSetStringW(HKEY_CURRENT_USER, keyPath, NULL, L"Quick Push Shell Extension");

    wnsprintfW(keyPath, 256, L"Software\\Classes\\CLSID\\%s\\InprocServer32", CLSID_STRW);
    RegSetStringW(HKEY_CURRENT_USER, keyPath, NULL, dllPath);
    RegSetStringW(HKEY_CURRENT_USER, keyPath, L"ThreadingModel", L"Apartment");

    RegSetStringW(HKEY_CURRENT_USER,
        L"Software\\Classes\\Directory\\Background\\shellex\\ContextMenuHandlers\\QuickPush",
        NULL, CLSID_STRW);
    RegSetStringW(HKEY_CURRENT_USER,
        L"Software\\Classes\\Directory\\shellex\\ContextMenuHandlers\\QuickPush",
        NULL, CLSID_STRW);

    return S_OK;
}

HRESULT __stdcall DllUnregisterServer(void) {
    wchar_t keyPath[256];

    SHDeleteKeyW(HKEY_CURRENT_USER,
        L"Software\\Classes\\Directory\\Background\\shellex\\ContextMenuHandlers\\QuickPush");
    SHDeleteKeyW(HKEY_CURRENT_USER,
        L"Software\\Classes\\Directory\\shellex\\ContextMenuHandlers\\QuickPush");

    wnsprintfW(keyPath, 256, L"Software\\Classes\\CLSID\\%s", CLSID_STRW);
    SHDeleteKeyW(HKEY_CURRENT_USER, keyPath);

    return S_OK;
}
