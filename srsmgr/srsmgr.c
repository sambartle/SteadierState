/*
 * srsmgr.c - Image-O-Tron 11,000 boot manager for Steadier State (Windows 11)
 *
 * One executable, four roles:
 *   srsmgr.exe /pe /phy D: /store "S:\EFI\Microsoft\Boot\BCD"
 *        WinPE boot screen (red). Launched by startnet.cmd on the SrS_Tools
 *        partition. Performs the VHD-chain actions with diskpart.
 *        Exit code: 0 = reboot, 1 = shut down, 2 = stay in WinPE (cmd).
 *   srsmgr.exe
 *        Desktop app (blue). Schedules actions for the next boot through
 *        the SrsMgr service, so ordinary users can use it.
 *   srsmgr.exe /service            (run by the Service Control Manager)
 *   srsmgr.exe /install | /uninstall | /status | /cancel
 *   srsmgr.exe /schedule <action> [/shutdown] [/now]
 *   srsmgr.exe /set <mode|autotarget|countdown> <value>
 *
 * Disk chain on the Physical_Drive partition:
 *   image.vhd  <-  intermediate.vhd (optional)  <-  snapshot.vhd
 * Settings / log:  \srsdirectives\srs.ini, history.log, srsmgr-last.log
 *
 * Build: see build.sh (MinGW-w64). No dependencies beyond Windows itself,
 * so the same exe runs in WinPE and on the desktop.
 */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <sddl.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include "resource.h"

#define APP_TITLE   L"Image-O-Tron 11,000"
#define SVC_NAME    L"SrsMgr"
#define SVC_DISPLAY L"Image-O-Tron 11,000 (Steadier State)"
#define PIPE_NAME   L"\\\\.\\pipe\\SrsMgr"
#define PHY_LABEL   L"Physical_Drive"
#define RB_DESC     L"Roll Back Windows"
#define SNAP_DESC   L"Windows 11 (Steadier State)"
#define RESP_MAX    65536           /* WCHARs */

/* ------------------------------------------------------------------ */
/* globals                                                             */
/* ------------------------------------------------------------------ */
static BOOL  g_pe = FALSE;                 /* running in WinPE         */
static WCHAR g_phy[MAX_PATH];              /* "D:\" or "\\?\Volume{..}\" */
static WCHAR g_phyLetter[4];               /* "D:" (PE only)           */
static WCHAR g_store[MAX_PATH + 16];       /* "/store \"...\"" or ""   */
static WCHAR g_lastErr[1024];

typedef struct {
    WCHAR mode[32];        /* gui | autorollback | direct | automerge */
    WCHAR autotarget[32];  /* intermediate | base                     */
    int   countdown;       /* seconds, 0 = wait forever               */
    WCHAR pending[32];     /* none | <action code>                    */
    WCHAR after[16];       /* reboot | shutdown                       */
} Config;

typedef struct {
    BOOL exists;
    ULONGLONG size;
    FILETIME mtime;
} Layer;

typedef struct {
    Layer image, inter, snap;
} Chain;

typedef struct {
    const WCHAR *code;
    const WCHAR *label;
    const WCHAR *confirm;   /* NULL = no confirmation */
} ActDef;

static const ActDef g_acts[] = {
    { L"continue",       L"Continue",
      NULL },
    { L"rollback_inter", L"Roll back to intermediate",
      L"Discard every change made since the intermediate was created?\n\n"
      L"snapshot.vhd is replaced with a fresh one on top of intermediate.vhd." },
    { L"rollback_base",  L"Roll back to base",
      L"Discard EVERYTHING since the base image, including the intermediate "
      L"(if there is one)?\n\nThis can't be undone." },
    { L"merge_inter",    L"Merge snapshot into intermediate",
      L"Merge the snapshot's changes permanently into intermediate.vhd?\n\n"
      L"This can't be undone." },
    { L"merge_base",     L"Merge all into base",
      L"Merge the snapshot (and the intermediate, if any) permanently into "
      L"image.vhd?\n\nThe base image itself changes. This can't be undone." },
    { L"promote",        L"Make snapshot the intermediate",
      L"Keep the current snapshot as the new intermediate baseline and start a "
      L"fresh snapshot on top of it?" },
    { L"initial",        L"Create initial snapshot", NULL },
};
#define N_ACTS (sizeof(g_acts) / sizeof(g_acts[0]))

static const ActDef *find_act(const WCHAR *code)
{
    for (size_t i = 0; i < N_ACTS; i++)
        if (_wcsicmp(g_acts[i].code, code) == 0) return &g_acts[i];
    return NULL;
}

static const WCHAR *mode_label(const WCHAR *m)
{
    if (!_wcsicmp(m, L"gui"))          return L"Show this screen on every boot";
    if (!_wcsicmp(m, L"autorollback")) return L"Always roll back automatically";
    if (!_wcsicmp(m, L"direct"))       return L"Straight to Windows";
    if (!_wcsicmp(m, L"automerge"))    return L"Always merge automatically";
    return m;
}

/* ------------------------------------------------------------------ */
/* small utilities                                                     */
/* ------------------------------------------------------------------ */
static void path_join(WCHAR *out, size_t cch, const WCHAR *a, const WCHAR *b)
{
    _snwprintf(out, cch, L"%ls%ls", a, b);
    out[cch - 1] = 0;
}

static void phy_path(WCHAR *out, const WCHAR *rel)
{
    path_join(out, MAX_PATH, g_phy, rel);
}

static BOOL file_exists(const WCHAR *p)
{
    DWORD a = GetFileAttributesW(p);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

static void now_str(WCHAR *out, size_t cch)
{
    SYSTEMTIME st;
    GetLocalTime(&st);
    _snwprintf(out, cch, L"%04u-%02u-%02u %02u:%02u:%02u",
               st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
}

static void ft_str(const FILETIME *ft, WCHAR *out, size_t cch)
{
    FILETIME lft;
    SYSTEMTIME st;
    FileTimeToLocalFileTime(ft, &lft);
    FileTimeToSystemTime(&lft, &st);
    _snwprintf(out, cch, L"%04u-%02u-%02u %02u:%02u",
               st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute);
}

static void size_str(ULONGLONG b, WCHAR *out, size_t cch)
{
    if (b >= 1024ULL * 1024 * 1024)
        _snwprintf(out, cch, L"%.1f GB", b / (1024.0 * 1024 * 1024));
    else if (b >= 100ULL * 1024 * 1024)
        _snwprintf(out, cch, L"%.0f MB", b / (1024.0 * 1024));
    else
        _snwprintf(out, cch, L"%.1f MB", b / (1024.0 * 1024));
}

static void write_utf8_append(const WCHAR *path, const WCHAR *text)
{
    HANDLE h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    char *buf = (char *)malloc(n);
    if (buf) {
        DWORD w;
        WideCharToMultiByte(CP_UTF8, 0, text, -1, buf, n, NULL, NULL);
        WriteFile(h, buf, (DWORD)(n - 1), &w, NULL);
        free(buf);
    }
    CloseHandle(h);
}

/* read a (small) text file as wide string; caller frees */
static WCHAR *read_text(const WCHAR *path, DWORD maxBytesFromEnd)
{
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return NULL;
    LARGE_INTEGER sz;
    GetFileSizeEx(h, &sz);
    DWORD len = (DWORD)sz.QuadPart;
    if (maxBytesFromEnd && len > maxBytesFromEnd) {
        LARGE_INTEGER off;
        off.QuadPart = sz.QuadPart - maxBytesFromEnd;
        SetFilePointerEx(h, off, NULL, FILE_BEGIN);
        len = maxBytesFromEnd;
    }
    char *buf = (char *)malloc(len + 1);
    DWORD rd = 0;
    if (!buf) { CloseHandle(h); return NULL; }
    ReadFile(h, buf, len, &rd, NULL);
    CloseHandle(h);
    buf[rd] = 0;
    int n = MultiByteToWideChar(CP_UTF8, 0, buf, (int)rd, NULL, 0);
    WCHAR *w = (WCHAR *)calloc(n + 1, sizeof(WCHAR));
    if (w) MultiByteToWideChar(CP_UTF8, 0, buf, (int)rd, w, n);
    free(buf);
    return w;
}

static void detail(const WCHAR *fmt, ...)
{
    if (!g_phy[0]) return;
    WCHAR buf[2048];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(buf, 2047, fmt, ap);
    buf[2047] = 0;
    va_end(ap);
    WCHAR p[MAX_PATH];
    phy_path(p, L"srsdirectives\\srsmgr-last.log");
    write_utf8_append(p, buf);
    write_utf8_append(p, L"\r\n");
}

static void detail_reset(const WCHAR *title)
{
    WCHAR p[MAX_PATH], t[32];
    if (!g_phy[0]) return;
    phy_path(p, L"srsdirectives\\srsmgr-last.log");
    DeleteFileW(p);
    now_str(t, 32);
    detail(L"=== %ls  %ls  (%ls) ===", t, title, g_pe ? L"WinPE" : L"Windows");
}

static void history(const WCHAR *action, const WCHAR *result)
{
    WCHAR p[MAX_PATH], t[32], line[512];
    if (!g_phy[0]) return;
    phy_path(p, L"srsdirectives\\history.log");
    now_str(t, 32);
    _snwprintf(line, 511, L"%ls  %-7ls  %-15ls  %ls\r\n", t,
               g_pe ? L"WinPE" : L"Windows", action, result);
    line[511] = 0;
    write_utf8_append(p, line);
}

/* ------------------------------------------------------------------ */
/* config (srs.ini - simple key=value, sections ignored)               */
/* ------------------------------------------------------------------ */
static void cfg_defaults(Config *c)
{
    wcscpy(c->mode, L"gui");
    wcscpy(c->autotarget, L"intermediate");
    c->countdown = 15;
    wcscpy(c->pending, L"none");
    wcscpy(c->after, L"reboot");
}

static void cfg_load(Config *c)
{
    WCHAR p[MAX_PATH];
    cfg_defaults(c);
    phy_path(p, L"srsdirectives\\srs.ini");
    WCHAR *t = read_text(p, 0);
    if (!t) return;
    WCHAR *ctx = NULL;
    for (WCHAR *ln = wcstok_s(t, L"\r\n", &ctx); ln; ln = wcstok_s(NULL, L"\r\n", &ctx)) {
        while (*ln == L' ' || *ln == L'\t') ln++;
        if (*ln == L';' || *ln == L'#' || *ln == L'[') continue;
        WCHAR *eq = wcschr(ln, L'=');
        if (!eq) continue;
        *eq = 0;
        WCHAR *k = ln, *v = eq + 1;
        /* trim */
        for (WCHAR *e = k + wcslen(k); e > k && (e[-1] == L' ' || e[-1] == L'\t'); ) *--e = 0;
        while (*v == L' ' || *v == L'\t') v++;
        for (WCHAR *e = v + wcslen(v); e > v && (e[-1] == L' ' || e[-1] == L'\t'); ) *--e = 0;
        if      (!_wcsicmp(k, L"mode"))       wcsncpy(c->mode, v, 31);
        else if (!_wcsicmp(k, L"autotarget")) wcsncpy(c->autotarget, v, 31);
        else if (!_wcsicmp(k, L"countdown"))  c->countdown = _wtoi(v);
        else if (!_wcsicmp(k, L"pending"))    wcsncpy(c->pending, v, 31);
        else if (!_wcsicmp(k, L"after"))      wcsncpy(c->after, v, 15);
    }
    free(t);
    if (c->countdown < 0) c->countdown = 0;
    if (c->countdown > 600) c->countdown = 600;
}

static BOOL cfg_save(const Config *c)
{
    WCHAR p[MAX_PATH], d[MAX_PATH], buf[1024];
    phy_path(d, L"srsdirectives");
    CreateDirectoryW(d, NULL);
    phy_path(p, L"srsdirectives\\srs.ini");
    _snwprintf(buf, 1023,
        L"; Image-O-Tron 11,000 / Steadier State settings\r\n"
        L"; mode       = gui | autorollback | direct | automerge\r\n"
        L"; autotarget = intermediate | base   (what auto modes roll back / merge to)\r\n"
        L"; countdown  = seconds before the boot screen continues (0 = wait forever)\r\n"
        L"; pending    = action to run silently on the next boot (none = nothing)\r\n"
        L"; after      = reboot | shutdown     (after the pending action)\r\n"
        L"[srs]\r\nmode=%ls\r\nautotarget=%ls\r\ncountdown=%d\r\npending=%ls\r\nafter=%ls\r\n",
        c->mode, c->autotarget, c->countdown, c->pending, c->after);
    buf[1023] = 0;
    DeleteFileW(p);
    write_utf8_append(p, buf);
    return file_exists(p);
}

/* ------------------------------------------------------------------ */
/* chain info                                                          */
/* ------------------------------------------------------------------ */
static void layer_get(const WCHAR *name, Layer *l)
{
    WCHAR p[MAX_PATH];
    WIN32_FILE_ATTRIBUTE_DATA fa;
    phy_path(p, name);
    ZeroMemory(l, sizeof(*l));
    if (GetFileAttributesExW(p, GetFileExInfoStandard, &fa) &&
        !(fa.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
        l->exists = TRUE;
        l->size = ((ULONGLONG)fa.nFileSizeHigh << 32) | fa.nFileSizeLow;
        l->mtime = fa.ftLastWriteTime;
    }
}

static void chain_get(Chain *c)
{
    layer_get(L"image.vhd", &c->image);
    layer_get(L"intermediate.vhd", &c->inter);
    layer_get(L"snapshot.vhd", &c->snap);
}

/* ------------------------------------------------------------------ */
/* running console tools (diskpart, bcdedit)                           */
/* ------------------------------------------------------------------ */
static DWORD run_cmd(const WCHAR *cmdline, WCHAR **outText)
{
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    HANDLE rd = NULL, wr = NULL;
    DWORD code = (DWORD)-1;
    if (outText) *outText = NULL;
    if (!CreatePipe(&rd, &wr, &sa, 0)) return code;
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdOutput = wr;
    si.hStdError = wr;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    WCHAR *cl = _wcsdup(cmdline);
    detail(L"> %ls", cmdline);
    BOOL ok = CreateProcessW(NULL, cl, NULL, NULL, TRUE, CREATE_NO_WINDOW,
                             NULL, NULL, &si, &pi);
    free(cl);
    CloseHandle(wr);
    if (!ok) {
        detail(L"  (could not start, error %lu)", GetLastError());
        CloseHandle(rd);
        return code;
    }
    size_t cap = 65536, len = 0;
    char *buf = (char *)malloc(cap);
    for (;;) {
        DWORD n = 0;
        if (len + 4096 > cap) { cap *= 2; buf = (char *)realloc(buf, cap); }
        if (!ReadFile(rd, buf + len, 4096, &n, NULL) || n == 0) break;
        len += n;
    }
    CloseHandle(rd);
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    int n = MultiByteToWideChar(CP_OEMCP, 0, buf, (int)len, NULL, 0);
    WCHAR *w = (WCHAR *)calloc(n + 1, sizeof(WCHAR));
    MultiByteToWideChar(CP_OEMCP, 0, buf, (int)len, w, n);
    free(buf);
    detail(L"%ls", w);
    detail(L"  (exit code %lu)", code);
    if (outText) *outText = w; else free(w);
    return code;
}

static BOOL diskpart(const WCHAR *script)
{
    WCHAR tmp[MAX_PATH], sp[MAX_PATH], cl[MAX_PATH + 32];
    GetTempPathW(MAX_PATH, tmp);
    path_join(sp, MAX_PATH, tmp, L"srsmgr-dp.txt");
    DeleteFileW(sp);
    WCHAR full[2048];
    _snwprintf(full, 2047, L"%ls\r\nexit\r\n", script);
    full[2047] = 0;
    /* diskpart reads the script in the OEM/ANSI code page; paths are ASCII */
    write_utf8_append(sp, full);
    detail(L"diskpart script:\r\n%ls", script);
    _snwprintf(cl, MAX_PATH + 31, L"diskpart.exe /s \"%ls\"", sp);
    DWORD rc = run_cmd(cl, NULL);
    DeleteFileW(sp);
    if (rc != 0) {
        _snwprintf(g_lastErr, 1023, L"diskpart failed (exit code %lu). Details are in "
                   L"\\srsdirectives\\srsmgr-last.log on the Physical Drive.", rc);
        return FALSE;
    }
    return TRUE;
}

static DWORD bcdedit(const WCHAR *args, WCHAR **out)
{
    WCHAR cl[1024];
    _snwprintf(cl, 1023, L"bcdedit.exe %ls %ls", g_store, args);
    cl[1023] = 0;
    return run_cmd(cl, out);
}

/* ------------------------------------------------------------------ */
/* BCD                                                                 */
/* ------------------------------------------------------------------ */
typedef struct {
    WCHAR rb[64];    /* "Roll Back Windows" entry GUID */
    WCHAR snap[64];  /* snapshot.vhd entry GUID         */
} BcdIds;

static void bcd_find(BcdIds *ids)
{
    WCHAR *out = NULL, *ctx = NULL;
    WCHAR cur[64] = L"";
    ZeroMemory(ids, sizeof(*ids));
    bcdedit(L"/enum osloader /v", &out);
    if (!out) return;
    for (WCHAR *ln = wcstok_s(out, L"\r\n", &ctx); ln; ln = wcstok_s(NULL, L"\r\n", &ctx)) {
        WCHAR key[64] = L"", *val;
        if (swscanf(ln, L"%63ls", key) != 1) continue;
        val = ln + wcslen(key);
        while (*val == L' ' || *val == L'\t') val++;
        if (!_wcsicmp(key, L"identifier")) {
            wcsncpy(cur, val, 63);
            cur[63] = 0;
        } else if (!_wcsicmp(key, L"description") && !_wcsicmp(val, RB_DESC)) {
            wcscpy(ids->rb, cur);
        } else if ((!_wcsicmp(key, L"device") || !_wcsicmp(key, L"osdevice")) &&
                   wcsstr(_wcslwr(val), L"snapshot.vhd")) {
            wcscpy(ids->snap, cur);
        }
    }
    free(out);
    detail(L"BCD: Roll Back Windows=%ls  snapshot=%ls",
           ids->rb[0] ? ids->rb : L"(none)", ids->snap[0] ? ids->snap : L"(none)");
}

/* PE only: create the snapshot boot entry if it's missing */
static BOOL bcd_ensure_snapshot(BcdIds *ids)
{
    if (ids->snap[0]) return TRUE;
    WCHAR *out = NULL, a[512];
    _snwprintf(a, 511, L"/create /d \"%ls\" /application osloader", SNAP_DESC);
    bcdedit(a, &out);
    if (out) {
        WCHAR *l = wcschr(out, L'{'), *r = l ? wcschr(l, L'}') : NULL;
        if (l && r && r - l < 60) { wcsncpy(ids->snap, l, r - l + 1); ids->snap[r - l + 1] = 0; }
        free(out);
    }
    if (!ids->snap[0]) {
        wcscpy(g_lastErr, L"Couldn't create the snapshot boot entry with bcdedit.");
        return FALSE;
    }
    const WCHAR *sets[] = {
        L"device vhd=[%ls]\\snapshot.vhd", L"osdevice vhd=[%ls]\\snapshot.vhd",
        L"path \\windows\\system32\\winload.efi", L"systemroot \\windows",
        L"inherit {bootloadersettings}", L"recoveryenabled no",
        L"nx OptIn", L"detecthal yes" };
    for (size_t i = 0; i < sizeof(sets) / sizeof(sets[0]); i++) {
        WCHAR v[256];
        _snwprintf(v, 255, sets[i], g_phyLetter);
        _snwprintf(a, 511, L"/set %ls %ls", ids->snap, v);
        bcdedit(a, NULL);
    }
    _snwprintf(a, 511, L"/displayorder %ls /addlast", ids->snap);
    bcdedit(a, NULL);
    return TRUE;
}

/* Make the boot entries match the mode.
 *   non-direct: default = Roll Back Windows (WinPE every boot)
 *   direct    : default = snapshot (Windows directly)
 * oneShotSnap: (PE) boot the snapshot once next time.
 * oneShotPE  : (Windows) go to WinPE once next time (scheduled action). */
static void bcd_apply(const Config *c, BOOL oneShotSnap, BOOL oneShotPE)
{
    BcdIds ids;
    WCHAR a[256];
    bcd_find(&ids);
    if (g_pe) bcd_ensure_snapshot(&ids);
    BOOL direct = !_wcsicmp(c->mode, L"direct");
    const WCHAR *def = direct ? ids.snap : ids.rb;
    if (def[0]) { _snwprintf(a, 255, L"/default %ls", def); bcdedit(a, NULL); }
    bcdedit(L"/timeout 0", NULL);
    if (oneShotSnap && ids.snap[0] && !direct) {
        _snwprintf(a, 255, L"/bootsequence %ls", ids.snap);
        bcdedit(a, NULL);
    } else if (oneShotPE && ids.rb[0]) {
        _snwprintf(a, 255, L"/bootsequence %ls", ids.rb);
        bcdedit(a, NULL);
    } else if (!oneShotSnap && !oneShotPE && !g_pe) {
        bcdedit(L"/deletevalue {bootmgr} bootsequence", NULL);
    }
}

/* ------------------------------------------------------------------ */
/* VHD chain actions (WinPE only)                                      */
/* ------------------------------------------------------------------ */
static BOOL dp_child(const WCHAR *child, const WCHAR *parent)
{
    WCHAR c[MAX_PATH], p[MAX_PATH], s[1024];
    phy_path(c, child);
    phy_path(p, parent);
    _snwprintf(s, 1023, L"create vdisk file=\"%ls\" parent=\"%ls\"", c, p);
    return diskpart(s);
}

static BOOL dp_merge(const WCHAR *child)
{
    WCHAR c[MAX_PATH], s[1024];
    phy_path(c, child);
    _snwprintf(s, 1023, L"select vdisk file=\"%ls\"\r\nmerge vdisk depth=1", c);
    return diskpart(s);
}

static BOOL del_vhd(const WCHAR *name)
{
    WCHAR p[MAX_PATH];
    phy_path(p, name);
    if (!file_exists(p)) return TRUE;
    DeleteFileW(p);
    if (file_exists(p)) {
        _snwprintf(g_lastErr, 1023, L"Couldn't delete %ls (error %lu).", name, GetLastError());
        detail(L"%ls", g_lastErr);
        return FALSE;
    }
    detail(L"deleted %ls", name);
    return TRUE;
}

static BOOL need(BOOL cond, const WCHAR *msg)
{
    if (!cond) { wcsncpy(g_lastErr, msg, 1023); detail(L"%ls", msg); }
    return cond;
}

static BOOL do_action(const WCHAR *code)
{
    Chain ch;
    chain_get(&ch);
    g_lastErr[0] = 0;
    detail(L"action %ls: image=%d intermediate=%d snapshot=%d", code,
           ch.image.exists, ch.inter.exists, ch.snap.exists);
    if (!need(ch.image.exists, L"image.vhd is missing from the Physical Drive.")) return FALSE;

    if (!_wcsicmp(code, L"continue")) {
        return need(ch.snap.exists, L"snapshot.vhd is missing.");
    }
    if (!_wcsicmp(code, L"initial")) {
        return del_vhd(L"snapshot.vhd") &&
               dp_child(L"snapshot.vhd", ch.inter.exists ? L"intermediate.vhd" : L"image.vhd");
    }
    if (!_wcsicmp(code, L"rollback_base")) {
        return del_vhd(L"snapshot.vhd") && del_vhd(L"intermediate.vhd") &&
               dp_child(L"snapshot.vhd", L"image.vhd");
    }
    if (!_wcsicmp(code, L"rollback_inter")) {
        if (!need(ch.inter.exists, L"There is no intermediate to roll back to.")) return FALSE;
        return del_vhd(L"snapshot.vhd") && dp_child(L"snapshot.vhd", L"intermediate.vhd");
    }
    if (!_wcsicmp(code, L"merge_inter")) {
        if (!need(ch.inter.exists, L"There is no intermediate to merge into.")) return FALSE;
        if (!need(ch.snap.exists, L"snapshot.vhd is missing.")) return FALSE;
        return dp_merge(L"snapshot.vhd") && del_vhd(L"snapshot.vhd") &&
               dp_child(L"snapshot.vhd", L"intermediate.vhd");
    }
    if (!_wcsicmp(code, L"merge_base")) {
        if (!need(ch.snap.exists, L"snapshot.vhd is missing.")) return FALSE;
        if (!dp_merge(L"snapshot.vhd")) return FALSE;
        if (ch.inter.exists && !dp_merge(L"intermediate.vhd")) return FALSE;
        return del_vhd(L"snapshot.vhd") && del_vhd(L"intermediate.vhd") &&
               dp_child(L"snapshot.vhd", L"image.vhd");
    }
    if (!_wcsicmp(code, L"promote")) {
        WCHAR s[MAX_PATH], i[MAX_PATH];
        if (!need(!ch.inter.exists, L"An intermediate already exists. Merge it or roll "
                  L"back to base first.")) return FALSE;
        if (!need(ch.snap.exists, L"snapshot.vhd is missing.")) return FALSE;
        phy_path(s, L"snapshot.vhd");
        phy_path(i, L"intermediate.vhd");
        if (!MoveFileW(s, i)) {
            _snwprintf(g_lastErr, 1023, L"Couldn't rename snapshot.vhd (error %lu).", GetLastError());
            return FALSE;
        }
        detail(L"renamed snapshot.vhd -> intermediate.vhd");
        if (!dp_child(L"snapshot.vhd", L"intermediate.vhd")) {
            MoveFileW(i, s);    /* put it back */
            return FALSE;
        }
        return TRUE;
    }
    _snwprintf(g_lastErr, 1023, L"Unknown action '%ls'.", code);
    return FALSE;
}

/* decide what an automatic mode does */
static const WCHAR *auto_action(const Config *c, const Chain *ch)
{
    BOOL toInter = ch->inter.exists && _wcsicmp(c->autotarget, L"base") != 0;
    if (!_wcsicmp(c->mode, L"autorollback")) return toInter ? L"rollback_inter" : L"rollback_base";
    if (!_wcsicmp(c->mode, L"automerge"))    return toInter ? L"merge_inter" : L"merge_base";
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Windows side: locate Physical_Drive, command handler, service       */
/* ------------------------------------------------------------------ */
static BOOL find_phy_volume(void)
{
    WCHAR vol[MAX_PATH], label[MAX_PATH + 1];
    HANDLE h = FindFirstVolumeW(vol, MAX_PATH);
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    BOOL found = FALSE;
    do {
        if (GetVolumeInformationW(vol, label, MAX_PATH, NULL, NULL, NULL, NULL, 0) &&
            !_wcsicmp(label, PHY_LABEL)) {
            /* prefer a drive letter (e.g. "D:\") if the volume has one;
               otherwise use the volume GUID path \\?\Volume{...}\ */
            WCHAR names[512];
            DWORD n = 0;
            wcscpy(g_phy, vol);
            if (GetVolumePathNamesForVolumeNameW(vol, names, 512, &n)) {
                for (WCHAR *q = names; *q; q += wcslen(q) + 1)
                    if (wcslen(q) == 3 && q[1] == L':') { wcscpy(g_phy, q); break; }
            }
            found = TRUE;
            break;
        }
    } while (FindNextVolumeW(h, vol, MAX_PATH));
    FindVolumeClose(h);
    return found;
}

static BOOL is_elevated(void)
{
    HANDLE t;
    TOKEN_ELEVATION e = { 0 };
    DWORD n;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &t)) return FALSE;
    GetTokenInformation(t, TokenElevation, &e, sizeof(e), &n);
    CloseHandle(t);
    return e.TokenIsElevated != 0;
}

static void enable_shutdown_priv(void)
{
    HANDLE t;
    TOKEN_PRIVILEGES tp;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &t)) return;
    LookupPrivilegeValueW(NULL, SE_SHUTDOWN_NAME, &tp.Privileges[0].Luid);
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(t, FALSE, &tp, 0, NULL, NULL);
    CloseHandle(t);
}

static void layer_kv(WCHAR *resp, const WCHAR *k, const Layer *l)
{
    WCHAR line[160];
    ULONGLONG ft = ((ULONGLONG)l->mtime.dwHighDateTime << 32) | l->mtime.dwLowDateTime;
    _snwprintf(line, 159, L"%ls=%d|%llu|%llu\n", k, l->exists, l->size, ft);
    wcsncat(resp, line, RESP_MAX - wcslen(resp) - 1);
}

/* Commands (one per pipe message):
 *   STATUS | CANCEL | HISTORY
 *   SCHEDULE <action> <reboot|shutdown> <0|1 now>
 *   SET <mode|autotarget|countdown> <value>                          */
static void handle_command(const WCHAR *req, WCHAR *resp)
{
    Config c;
    WCHAR cmd[32] = L"", a1[64] = L"", a2[64] = L"", a3[16] = L"";
    resp[0] = 0;
    if (!g_phy[0] && !find_phy_volume()) {
        wcscpy(resp, L"ERR Can't find the Physical_Drive volume.");
        return;
    }
    swscanf(req, L"%31ls %63ls %63ls %15ls", cmd, a1, a2, a3);
    cfg_load(&c);

    if (!_wcsicmp(cmd, L"STATUS")) {
        Chain ch;
        chain_get(&ch);
        _snwprintf(resp, RESP_MAX - 1,
                   L"OK\nmode=%ls\nautotarget=%ls\ncountdown=%d\npending=%ls\nafter=%ls\nphy=%ls\n",
                   c.mode, c.autotarget, c.countdown, c.pending, c.after, g_phy);
        layer_kv(resp, L"image", &ch.image);
        layer_kv(resp, L"intermediate", &ch.inter);
        layer_kv(resp, L"snapshot", &ch.snap);
        return;
    }
    if (!_wcsicmp(cmd, L"HISTORY")) {
        WCHAR p[MAX_PATH];
        phy_path(p, L"srsdirectives\\history.log");
        WCHAR *t = read_text(p, 60000);
        _snwprintf(resp, RESP_MAX - 1, L"OK\n%ls", t ? t : L"(no history yet)");
        free(t);
        return;
    }
    if (!_wcsicmp(cmd, L"CANCEL")) {
        wcscpy(c.pending, L"none");
        wcscpy(c.after, L"reboot");
        cfg_save(&c);
        detail_reset(L"cancel");
        bcd_apply(&c, FALSE, FALSE);
        history(L"cancel", L"scheduled action cancelled");
        wcscpy(resp, L"OK");
        return;
    }
    if (!_wcsicmp(cmd, L"SCHEDULE")) {
        /* "rollback" / "merge" = to the intermediate if there is one and
           autotarget isn't "base", otherwise to the base (for hooks) */
        if (!_wcsicmp(a1, L"rollback") || !_wcsicmp(a1, L"merge")) {
            Chain ch;
            chain_get(&ch);
            BOOL toInter = ch.inter.exists && _wcsicmp(c.autotarget, L"base") != 0;
            if (!_wcsicmp(a1, L"rollback")) wcscpy(a1, toInter ? L"rollback_inter" : L"rollback_base");
            else                            wcscpy(a1, toInter ? L"merge_inter" : L"merge_base");
        }
        const ActDef *d = find_act(a1);
        if (!d || !_wcsicmp(a1, L"initial") || !_wcsicmp(a1, L"continue")) {
            wcscpy(resp, L"ERR Unknown action.");
            return;
        }
        wcsncpy(c.pending, d->code, 31);
        wcscpy(c.after, !_wcsicmp(a2, L"shutdown") ? L"shutdown" : L"reboot");
        if (!cfg_save(&c)) { wcscpy(resp, L"ERR Couldn't write srs.ini."); return; }
        detail_reset(L"schedule");
        bcd_apply(&c, FALSE, TRUE);
        history(d->code, L"scheduled for next boot");
        if (!wcscmp(a3, L"1")) {
            enable_shutdown_priv();
            InitiateSystemShutdownExW(NULL, (LPWSTR)L"Image-O-Tron: restarting to run the scheduled action.",
                                      5, TRUE, TRUE, SHTDN_REASON_MAJOR_OTHER | SHTDN_REASON_FLAG_PLANNED);
        }
        wcscpy(resp, L"OK");
        return;
    }
    if (!_wcsicmp(cmd, L"SET")) {
        if (!_wcsicmp(a1, L"mode")) {
            if (_wcsicmp(a2, L"gui") && _wcsicmp(a2, L"autorollback") &&
                _wcsicmp(a2, L"direct") && _wcsicmp(a2, L"automerge")) {
                wcscpy(resp, L"ERR mode must be gui, autorollback, direct or automerge.");
                return;
            }
            wcsncpy(c.mode, a2, 31);
            _wcslwr(c.mode);
        } else if (!_wcsicmp(a1, L"autotarget")) {
            if (_wcsicmp(a2, L"intermediate") && _wcsicmp(a2, L"base")) {
                wcscpy(resp, L"ERR autotarget must be intermediate or base.");
                return;
            }
            wcsncpy(c.autotarget, a2, 31);
            _wcslwr(c.autotarget);
        } else if (!_wcsicmp(a1, L"countdown")) {
            c.countdown = _wtoi(a2);
            if (c.countdown < 0) c.countdown = 0;
            if (c.countdown > 600) c.countdown = 600;
        } else {
            wcscpy(resp, L"ERR Unknown setting.");
            return;
        }
        if (!cfg_save(&c)) { wcscpy(resp, L"ERR Couldn't write srs.ini."); return; }
        detail_reset(L"set");
        bcd_apply(&c, FALSE, _wcsicmp(c.pending, L"none") != 0);
        WCHAR r[128];
        _snwprintf(r, 127, L"%ls = %ls", a1, a2);
        history(L"setting", r);
        wcscpy(resp, L"OK");
        return;
    }
    wcscpy(resp, L"ERR Unknown command.");
}

/* ---- service ---- */
static SERVICE_STATUS_HANDLE g_svcH;
static SERVICE_STATUS g_svcS;
static volatile LONG g_stop = 0;

static void svc_set(DWORD st)
{
    g_svcS.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_svcS.dwCurrentState = st;
    g_svcS.dwControlsAccepted = (st == SERVICE_RUNNING) ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
    SetServiceStatus(g_svcH, &g_svcS);
}

static DWORD WINAPI svc_ctrl(DWORD c, DWORD t, LPVOID d, LPVOID x)
{
    (void)t; (void)d; (void)x;
    if (c == SERVICE_CONTROL_STOP || c == SERVICE_CONTROL_SHUTDOWN) {
        InterlockedExchange(&g_stop, 1);
        svc_set(SERVICE_STOP_PENDING);
        WCHAR r[8];
        DWORD n;
        CallNamedPipeW(PIPE_NAME, (LPVOID)L"PING", 10, r, sizeof(r), &n, 500); /* unblock */
    }
    return NO_ERROR;
}

static void pipe_server(void)
{
    PSECURITY_DESCRIPTOR sd = NULL;
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, FALSE };
    /* SYSTEM + Administrators full; Authenticated Users read/write (anyone may use it) */
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)", SDDL_REVISION_1, &sd, NULL))
        sa.lpSecurityDescriptor = sd;
    WCHAR *req = (WCHAR *)malloc(4096 * sizeof(WCHAR));
    WCHAR *resp = (WCHAR *)malloc(RESP_MAX * sizeof(WCHAR));
    while (!g_stop) {
        HANDLE h = CreateNamedPipeW(PIPE_NAME, PIPE_ACCESS_DUPLEX,
                                    PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
                                    1, RESP_MAX * 2, 8192, 0, &sa);
        if (h == INVALID_HANDLE_VALUE) { Sleep(1000); continue; }
        BOOL con = ConnectNamedPipe(h, NULL) ? TRUE : (GetLastError() == ERROR_PIPE_CONNECTED);
        if (con && !g_stop) {
            DWORD n = 0;
            if (ReadFile(h, req, 4095 * sizeof(WCHAR), &n, NULL)) {
                req[n / sizeof(WCHAR)] = 0;
                if (wcscmp(req, L"PING") == 0) wcscpy(resp, L"OK");
                else handle_command(req, resp);
                WriteFile(h, resp, (DWORD)((wcslen(resp) + 1) * sizeof(WCHAR)), &n, NULL);
                FlushFileBuffers(h);
            }
        }
        DisconnectNamedPipe(h);
        CloseHandle(h);
    }
    free(req);
    free(resp);
    if (sd) LocalFree(sd);
}

static void WINAPI svc_main(DWORD argc, LPWSTR *argv)
{
    (void)argc; (void)argv;
    g_svcH = RegisterServiceCtrlHandlerExW(SVC_NAME, svc_ctrl, NULL);
    if (!g_svcH) return;
    svc_set(SERVICE_RUNNING);
    /* At every Windows start make the boot entries match the mode
     * (replaces the old bcddefault scheduled task). */
    if (find_phy_volume()) {
        Config c;
        cfg_load(&c);
        detail_reset(L"service start");
        bcd_apply(&c, FALSE, _wcsicmp(c.pending, L"none") != 0);
    }
    pipe_server();
    svc_set(SERVICE_STOPPED);
}

/* ---- client side ---- */
static BOOL pipe_call(const WCHAR *req, WCHAR *resp)
{
    DWORD n = 0;
    resp[0] = 0;
    if (CallNamedPipeW(PIPE_NAME, (LPVOID)req, (DWORD)((wcslen(req) + 1) * sizeof(WCHAR)),
                       resp, RESP_MAX * sizeof(WCHAR) - 2, &n, 5000)) {
        resp[n / sizeof(WCHAR)] = 0;
        return TRUE;
    }
    /* service not reachable: if we're elevated, do it ourselves */
    if (is_elevated() && (g_phy[0] || find_phy_volume())) {
        handle_command(req, resp);
        return TRUE;
    }
    _snwprintf(resp, 255, L"ERR The %ls service isn't running and this program isn't "
               L"elevated, so it can't do anything.", SVC_NAME);
    return FALSE;
}

static const WCHAR *kv_get(const WCHAR *resp, const WCHAR *key, WCHAR *out, size_t cch)
{
    size_t kl = wcslen(key);
    const WCHAR *p = resp;
    out[0] = 0;
    while (p && *p) {
        if (!wcsncmp(p, key, kl) && p[kl] == L'=') {
            const WCHAR *e = wcschr(p, L'\n');
            size_t l = e ? (size_t)(e - (p + kl + 1)) : wcslen(p + kl + 1);
            if (l >= cch) l = cch - 1;
            wcsncpy(out, p + kl + 1, l);
            out[l] = 0;
            return out;
        }
        p = wcschr(p, L'\n');
        if (p) p++;
    }
    return out;
}

static void layer_parse(const WCHAR *resp, const WCHAR *key, Layer *l)
{
    WCHAR v[128];
    int ex = 0;
    unsigned long long sz = 0, ft = 0;
    ZeroMemory(l, sizeof(*l));
    kv_get(resp, key, v, 128);
    if (swscanf(v, L"%d|%llu|%llu", &ex, &sz, &ft) == 3) {
        l->exists = ex;
        l->size = sz;
        l->mtime.dwLowDateTime = (DWORD)ft;
        l->mtime.dwHighDateTime = (DWORD)(ft >> 32);
    }
}

/* ------------------------------------------------------------------ */
/* GUI                                                                 */
/* ------------------------------------------------------------------ */
enum {
    IDC_LIST = 100, IDC_MODELINE, IDC_PENDING, IDC_STATUS,
    IDC_ACT0 = 200,                   /* IDC_ACT0 + index into g_acts */
    IDC_CHK_SHUT = 300, IDC_CHK_NOW,
    IDC_CB_MODE, IDC_CB_TARGET, IDC_ED_COUNT, IDC_B_SAVECOUNT,
    IDC_B_CMD, IDC_B_HIST, IDC_B_CANCEL, IDC_B_REFRESH,
    IDC_LBL1, IDC_LBL2, IDC_LBL3, IDC_GRP_CHAIN, IDC_GRP_SET
};
#define WM_APP_START (WM_APP + 1)
#define WM_APP_DONE  (WM_APP + 2)
#define TIMER_COUNT 1

static HWND g_hwnd;
static HFONT g_font, g_fontB, g_fontBtn;
static HBITMAP g_banner;
static int g_dpi = 96;
static Config g_cfg;
static Chain g_chain;
static int g_count = -1;                  /* remaining seconds, -1 = off */
static BOOL g_busy = FALSE, g_svcOk = FALSE;
static WCHAR g_autoAction[32] = L"";      /* PE: action to run automatically */
static BOOL g_autoFromPending = FALSE;
static WCHAR g_runAction[32];

#define S(x) MulDiv((x), g_dpi, 96)
#define BANNER_H 170
#define CLIENT_W 780
#define CLIENT_H (g_pe ? 592 : 620)

static const WCHAR *g_modes[] = { L"gui", L"autorollback", L"direct", L"automerge" };

static HWND ctl(const WCHAR *cls, const WCHAR *txt, DWORD style, int x, int y, int w, int h, int id, HFONT f)
{
    HWND c = CreateWindowExW(0, cls, txt, WS_CHILD | WS_VISIBLE | style, S(x), S(y), S(w), S(h),
                             g_hwnd, (HMENU)(INT_PTR)id, GetModuleHandleW(NULL), NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)(f ? f : g_font), TRUE);
    return c;
}

static void set_status(const WCHAR *fmt, ...)
{
    WCHAR b[1024];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(b, 1023, fmt, ap);
    b[1023] = 0;
    va_end(ap);
    SetDlgItemTextW(g_hwnd, IDC_STATUS, b);
}

static void stop_countdown(void)
{
    if (g_count >= 0) {
        KillTimer(g_hwnd, TIMER_COUNT);
        g_count = -1;
        if (!g_busy) set_status(L"Countdown stopped. Choose an action.");
    }
}

static void refresh_state(void)
{
    if (g_pe) {
        cfg_load(&g_cfg);
        chain_get(&g_chain);
        g_svcOk = TRUE;
    } else {
        WCHAR *r = (WCHAR *)malloc(RESP_MAX * sizeof(WCHAR)), v[64];
        g_svcOk = pipe_call(L"STATUS", r) && !wcsncmp(r, L"OK", 2);
        cfg_defaults(&g_cfg);
        ZeroMemory(&g_chain, sizeof(g_chain));
        if (g_svcOk) {
            wcsncpy(g_cfg.mode, kv_get(r, L"mode", v, 64), 31);
            wcsncpy(g_cfg.autotarget, kv_get(r, L"autotarget", v, 64), 31);
            g_cfg.countdown = _wtoi(kv_get(r, L"countdown", v, 64));
            wcsncpy(g_cfg.pending, kv_get(r, L"pending", v, 64), 31);
            wcsncpy(g_cfg.after, kv_get(r, L"after", v, 64), 15);
            layer_parse(r, L"image", &g_chain.image);
            layer_parse(r, L"intermediate", &g_chain.inter);
            layer_parse(r, L"snapshot", &g_chain.snap);
        } else {
            set_status(L"%ls", r + (wcsncmp(r, L"ERR ", 4) ? 0 : 4));
        }
        free(r);
    }

    /* chain list */
    HWND lv = GetDlgItem(g_hwnd, IDC_LIST);
    ListView_DeleteAllItems(lv);
    struct { const WCHAR *name, *file; Layer *l; } rows[] = {
        { L"Base", L"image.vhd", &g_chain.image },
        { L"Intermediate", L"intermediate.vhd", &g_chain.inter },
        { L"Snapshot (running)", L"snapshot.vhd", &g_chain.snap } };
    for (int i = 0; i < 3; i++) {
        WCHAR sz[32], dt[32];
        LVITEMW it;
        ZeroMemory(&it, sizeof(it));
        it.mask = LVIF_TEXT;
        it.iItem = i;
        it.pszText = (LPWSTR)rows[i].name;
        ListView_InsertItem(lv, &it);
        ListView_SetItemText(lv, i, 1, rows[i].l->exists ? (LPWSTR)rows[i].file : (LPWSTR)L"(none)");
        if (rows[i].l->exists) {
            size_str(rows[i].l->size, sz, 32);
            ft_str(&rows[i].l->mtime, dt, 32);
            ListView_SetItemText(lv, i, 2, sz);
            ListView_SetItemText(lv, i, 3, dt);
        }
    }

    /* mode line + settings controls */
    WCHAR ml[256];
    if (!_wcsicmp(g_cfg.mode, L"gui"))
        _snwprintf(ml, 255, L"Boot mode: %ls (countdown %d s, then Continue)", mode_label(g_cfg.mode), g_cfg.countdown);
    else if (!_wcsicmp(g_cfg.mode, L"autorollback") || !_wcsicmp(g_cfg.mode, L"automerge"))
        _snwprintf(ml, 255, L"Boot mode: %ls (to the %ls)", mode_label(g_cfg.mode),
                   !_wcsicmp(g_cfg.autotarget, L"base") ? L"base" : L"intermediate if there is one, else base");
    else
        _snwprintf(ml, 255, L"Boot mode: %ls", mode_label(g_cfg.mode));
    SetDlgItemTextW(g_hwnd, IDC_MODELINE, ml);

    for (int i = 0; i < 4; i++)
        if (!_wcsicmp(g_cfg.mode, g_modes[i])) SendDlgItemMessageW(g_hwnd, IDC_CB_MODE, CB_SETCURSEL, i, 0);
    SendDlgItemMessageW(g_hwnd, IDC_CB_TARGET, CB_SETCURSEL, !_wcsicmp(g_cfg.autotarget, L"base") ? 1 : 0, 0);
    SetDlgItemInt(g_hwnd, IDC_ED_COUNT, g_cfg.countdown, FALSE);

    if (!g_pe) {
        WCHAR pl[256];
        const ActDef *d = find_act(g_cfg.pending);
        if (d && _wcsicmp(g_cfg.pending, L"none"))
            _snwprintf(pl, 255, L"Scheduled for next boot: %ls%ls", d->label,
                       !_wcsicmp(g_cfg.after, L"shutdown") ? L", then shut down" : L"");
        else
            wcscpy(pl, L"Nothing scheduled.");
        SetDlgItemTextW(g_hwnd, IDC_PENDING, pl);
        EnableWindow(GetDlgItem(g_hwnd, IDC_B_CANCEL), g_svcOk && d && _wcsicmp(g_cfg.pending, L"none"));
    }

    /* enable/disable action buttons */
    BOOL ok = !g_busy && g_svcOk && g_chain.image.exists;
    for (size_t i = 0; i < N_ACTS; i++) {
        HWND b = GetDlgItem(g_hwnd, IDC_ACT0 + (int)i);
        if (!b) continue;
        BOOL en = ok;
        const WCHAR *c = g_acts[i].code;
        if (!_wcsicmp(c, L"rollback_inter") || !_wcsicmp(c, L"merge_inter")) en = en && g_chain.inter.exists;
        if (!_wcsicmp(c, L"promote")) en = en && !g_chain.inter.exists && g_chain.snap.exists;
        if (!_wcsicmp(c, L"merge_base") || !_wcsicmp(c, L"merge_inter") || !_wcsicmp(c, L"continue"))
            en = en && g_chain.snap.exists;
        EnableWindow(b, en);
    }
    int ids[] = { IDC_CB_MODE, IDC_CB_TARGET, IDC_ED_COUNT, IDC_B_SAVECOUNT };
    for (int i = 0; i < 4; i++) EnableWindow(GetDlgItem(g_hwnd, ids[i]), !g_busy && g_svcOk);
}

/* ---- PE worker ---- */
static DWORD WINAPI worker(LPVOID p)
{
    (void)p;
    BOOL ok = do_action(g_runAction);
    PostMessageW(g_hwnd, WM_APP_DONE, ok, 0);
    return 0;
}

static void pe_start(const WCHAR *code)
{
    const ActDef *d = find_act(code);
    stop_countdown();
    g_busy = TRUE;
    wcsncpy(g_runAction, code, 31);
    refresh_state();
    detail_reset(d ? d->label : code);
    if (!_wcsicmp(code, L"merge_inter") || !_wcsicmp(code, L"merge_base"))
        set_status(L"Working: %ls ... merging can take several minutes. Please wait.", d ? d->label : code);
    else
        set_status(L"Working: %ls ...", d ? d->label : code);
    SetCursor(LoadCursor(NULL, IDC_WAIT));
    CloseHandle(CreateThread(NULL, 0, worker, NULL, 0, NULL));
}

static void pe_finish(BOOL ok)
{
    g_busy = FALSE;
    const ActDef *d = find_act(g_runAction);
    history(g_runAction, ok ? L"OK" : g_lastErr);
    if (!ok) {
        if (g_autoFromPending) {
            /* don't retry a failed scheduled action on every boot */
            Config c;
            cfg_load(&c);
            wcscpy(c.pending, L"none");
            wcscpy(c.after, L"reboot");
            cfg_save(&c);
            history(g_runAction, L"scheduled action cleared after the failure above");
            g_autoFromPending = FALSE;
        }
        refresh_state();
        set_status(L"FAILED: %ls", g_lastErr);
        WCHAR m[1400];
        _snwprintf(m, 1399, L"%ls failed:\n\n%ls\n\nNo files have been deleted. You can try another "
                   L"action, or open a command prompt.", d ? d->label : g_runAction, g_lastErr);
        MessageBoxW(g_hwnd, m, APP_TITLE, MB_ICONERROR);
        return;
    }
    BOOL shut = IsDlgButtonChecked(g_hwnd, IDC_CHK_SHUT) == BST_CHECKED;
    if (g_autoFromPending) shut = !_wcsicmp(g_cfg.after, L"shutdown");
    /* clear any pending action and point the boot entries at the snapshot */
    Config c;
    cfg_load(&c);
    wcscpy(c.pending, L"none");
    wcscpy(c.after, L"reboot");
    cfg_save(&c);
    bcd_apply(&c, TRUE, FALSE);
    set_status(L"Done. %ls...", shut ? L"Shutting down" : L"Restarting into Windows");
    UpdateWindow(g_hwnd);
    Sleep(1200);
    PostQuitMessage(shut ? 1 : 0);
}

/* ---- desktop actions ---- */
static void desk_schedule(const WCHAR *code)
{
    const ActDef *d = find_act(code);
    BOOL now = IsDlgButtonChecked(g_hwnd, IDC_CHK_NOW) == BST_CHECKED;
    BOOL shut = IsDlgButtonChecked(g_hwnd, IDC_CHK_SHUT) == BST_CHECKED;
    WCHAR q[1024], req[128], *r;
    _snwprintf(q, 1023, L"%ls\n\nThis will happen during the %ls%ls.",
               d->confirm ? d->confirm : d->label,
               now ? L"restart that starts as soon as you click OK" : L"next restart",
               shut ? L", and the PC will then shut down" : L"");
    if (MessageBoxW(g_hwnd, q, d->label, MB_OKCANCEL | MB_ICONQUESTION) != IDOK) return;
    _snwprintf(req, 127, L"SCHEDULE %ls %ls %d", code, shut ? L"shutdown" : L"reboot", now ? 1 : 0);
    r = (WCHAR *)malloc(RESP_MAX * sizeof(WCHAR));
    pipe_call(req, r);
    if (wcsncmp(r, L"OK", 2)) MessageBoxW(g_hwnd, r, APP_TITLE, MB_ICONERROR);
    else set_status(now ? L"Scheduled. Restarting..." : L"Scheduled for the next restart.");
    free(r);
    refresh_state();
}

static void apply_setting(const WCHAR *key, const WCHAR *val)
{
    if (g_pe) {
        Config c;
        cfg_load(&c);
        if (!_wcsicmp(key, L"mode")) wcsncpy(c.mode, val, 31);
        else if (!_wcsicmp(key, L"autotarget")) wcsncpy(c.autotarget, val, 31);
        else c.countdown = _wtoi(val);
        cfg_save(&c);
        WCHAR r[128];
        _snwprintf(r, 127, L"%ls = %ls", key, val);
        history(L"setting", r);
    } else {
        WCHAR req[128], *r = (WCHAR *)malloc(RESP_MAX * sizeof(WCHAR));
        _snwprintf(req, 127, L"SET %ls %ls", key, val);
        pipe_call(req, r);
        if (wcsncmp(r, L"OK", 2)) MessageBoxW(g_hwnd, r, APP_TITLE, MB_ICONERROR);
        free(r);
    }
    refresh_state();
    set_status(L"Saved: %ls = %ls", key, val);
}

static void show_history(void)
{
    WCHAR tmp[MAX_PATH], p[MAX_PATH], cl[MAX_PATH * 2];
    if (g_pe) {
        phy_path(p, L"srsdirectives\\history.log");
        if (!file_exists(p)) write_utf8_append(p, L"");
    } else {
        WCHAR *r = (WCHAR *)malloc(RESP_MAX * sizeof(WCHAR));
        pipe_call(L"HISTORY", r);
        GetTempPathW(MAX_PATH, tmp);
        path_join(p, MAX_PATH, tmp, L"image-o-tron-history.txt");
        DeleteFileW(p);
        write_utf8_append(p, wcsncmp(r, L"OK\n", 3) ? r : r + 3);
        free(r);
    }
    _snwprintf(cl, MAX_PATH * 2 - 1, L"notepad.exe \"%ls\"", p);
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    if (CreateProcessW(NULL, cl, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
}

static void build_ui(void)
{
    BOOL pe = g_pe;
    int y = BANNER_H + 8;

    ctl(L"BUTTON", L"Disk chain", BS_GROUPBOX, 10, y, 760, 136, IDC_GRP_CHAIN, g_fontB);
    HWND lv = ctl(WC_LISTVIEWW, L"", LVS_REPORT | LVS_NOSORTHEADER | LVS_SINGLESEL | WS_BORDER,
                  20, y + 22, 740, 104, IDC_LIST, NULL);
    ListView_SetExtendedListViewStyle(lv, LVS_EX_FULLROWSELECT);
    const WCHAR *cols[] = { L"Layer", L"File", L"Size", L"Last changed" };
    int cw[] = { 200, 200, 140, 180 };
    for (int i = 0; i < 4; i++) {
        LVCOLUMNW c;
        ZeroMemory(&c, sizeof(c));
        c.mask = LVCF_TEXT | LVCF_WIDTH;
        c.pszText = (LPWSTR)cols[i];
        c.cx = S(cw[i]);
        ListView_InsertColumn(lv, i, &c);
    }
    y += 144;
    ctl(L"STATIC", L"", SS_LEFT, 12, y, 756, 20, IDC_MODELINE, g_fontB);
    y += 22;
    if (!pe) { ctl(L"STATIC", L"", SS_LEFT, 12, y, 756, 20, IDC_PENDING, NULL); y += 22; }
    else y += 4;

    /* action buttons: 2 rows x 3 */
    const WCHAR *order[6];
    int n = 0;
    if (pe) order[n++] = L"continue";
    order[n++] = L"rollback_inter";
    order[n++] = L"rollback_base";
    order[n++] = L"merge_inter";
    order[n++] = L"merge_base";
    order[n++] = L"promote";
    for (int i = 0; i < n; i++) {
        int idx = 0;
        for (size_t k = 0; k < N_ACTS; k++) if (!wcscmp(g_acts[k].code, order[i])) idx = (int)k;
        int col = i % 3, row = i / 3;
        ctl(L"BUTTON", g_acts[idx].label, BS_PUSHBUTTON, 10 + col * 255, y + row * 46, 245, 40,
            IDC_ACT0 + idx, g_fontBtn);
    }
    if (!pe)   /* 6th slot on the desktop: cancel the scheduled action */
        ctl(L"BUTTON", L"Cancel scheduled action", BS_PUSHBUTTON, 10 + 2 * 255, y + 46, 245, 40,
            IDC_B_CANCEL, g_fontBtn);
    y += 96;

    ctl(L"BUTTON", pe ? L"Shut down afterwards (instead of starting Windows)"
                      : L"Shut down after the action (instead of starting Windows)",
        BS_AUTOCHECKBOX, 12, y, 400, 22, IDC_CHK_SHUT, NULL);
    if (!pe) ctl(L"BUTTON", L"Restart now to do it", BS_AUTOCHECKBOX, 430, y, 300, 22, IDC_CHK_NOW, NULL);
    y += 30;

    ctl(L"BUTTON", L"Settings", BS_GROUPBOX, 10, y, 760, 70, IDC_GRP_SET, g_fontB);
    ctl(L"STATIC", L"Boot mode", SS_LEFT, 22, y + 22, 120, 18, IDC_LBL1, NULL);
    HWND cb = ctl(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL, 22, y + 40, 300, 200, IDC_CB_MODE, NULL);
    for (int i = 0; i < 4; i++) SendMessageW(cb, CB_ADDSTRING, 0, (LPARAM)mode_label(g_modes[i]));
    ctl(L"STATIC", L"Automatic modes act on", SS_LEFT, 340, y + 22, 200, 18, IDC_LBL2, NULL);
    cb = ctl(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL, 340, y + 40, 250, 200, IDC_CB_TARGET, NULL);
    SendMessageW(cb, CB_ADDSTRING, 0, (LPARAM)L"Intermediate (if there is one)");
    SendMessageW(cb, CB_ADDSTRING, 0, (LPARAM)L"Base");
    ctl(L"STATIC", L"Countdown (s)", SS_LEFT, 608, y + 22, 120, 18, IDC_LBL3, NULL);
    ctl(L"EDIT", L"", ES_NUMBER | WS_BORDER, 608, y + 40, 60, 24, IDC_ED_COUNT, NULL);
    ctl(L"BUTTON", L"Save", BS_PUSHBUTTON, 676, y + 39, 84, 26, IDC_B_SAVECOUNT, NULL);
    y += 80;

    if (pe) ctl(L"BUTTON", L"Command prompt", BS_PUSHBUTTON, 10, y, 150, 30, IDC_B_CMD, NULL);
    else    ctl(L"BUTTON", L"Refresh", BS_PUSHBUTTON, 10, y, 150, 30, IDC_B_REFRESH, NULL);
    ctl(L"BUTTON", L"History", BS_PUSHBUTTON, 170, y, 110, 30, IDC_B_HIST, NULL);
    ctl(L"STATIC", L"", SS_LEFT, 292, y - 2, 478, 38, IDC_STATUS, g_fontB);
}

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_CREATE:
        g_hwnd = h;
        build_ui();
        refresh_state();
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        if (g_banner) {
            HDC mdc = CreateCompatibleDC(dc);
            BITMAP bm;
            GetObject(g_banner, sizeof(bm), &bm);
            HGDIOBJ old = SelectObject(mdc, g_banner);
            RECT rc;
            GetClientRect(h, &rc);
            SetStretchBltMode(dc, HALFTONE);
            StretchBlt(dc, 0, 0, rc.right, S(BANNER_H), mdc, 0, 0, bm.bmWidth, bm.bmHeight, SRCCOPY);
            SelectObject(mdc, old);
            DeleteDC(mdc);
        }
        EndPaint(h, &ps);
        return 0;
    }
    case WM_CTLCOLORSTATIC:
        if ((HWND)l == GetDlgItem(h, IDC_STATUS)) {
            SetBkMode((HDC)w, TRANSPARENT);
            SetTextColor((HDC)w, g_pe ? RGB(170, 20, 20) : RGB(10, 70, 160));
            return (LRESULT)GetSysColorBrush(COLOR_BTNFACE);
        }
        break;
    case WM_APP_START:
        pe_start(g_autoAction);
        return 0;
    case WM_APP_DONE:
        SetCursor(LoadCursor(NULL, IDC_ARROW));
        pe_finish((BOOL)w);
        return 0;
    case WM_TIMER:
        if (w == TIMER_COUNT && g_count >= 0) {
            if (g_count == 0) {
                KillTimer(h, TIMER_COUNT);
                g_count = -1;
                pe_start(L"continue");
            } else {
                set_status(L"Continuing in %d s...  (click or press a key to stop)", g_count);
                g_count--;
            }
        }
        return 0;
    case WM_SETCURSOR:
        if (g_busy) { SetCursor(LoadCursor(NULL, IDC_WAIT)); return TRUE; }
        break;
    case WM_COMMAND: {
        int id = LOWORD(w), code = HIWORD(w);
        if (g_busy) return 0;
        if (id >= IDC_ACT0 && id < IDC_ACT0 + (int)N_ACTS && code == BN_CLICKED) {
            const ActDef *d = &g_acts[id - IDC_ACT0];
            stop_countdown();
            if (g_pe) {
                if (d->confirm && MessageBoxW(h, d->confirm, d->label, MB_OKCANCEL | MB_ICONWARNING) != IDOK)
                    return 0;
                g_autoFromPending = FALSE;
                pe_start(d->code);
            } else {
                desk_schedule(d->code);
            }
            return 0;
        }
        switch (id) {
        case IDC_CB_MODE:
            if (code == CBN_SELCHANGE) {
                int i = (int)SendDlgItemMessageW(h, IDC_CB_MODE, CB_GETCURSEL, 0, 0);
                if (i >= 0 && i < 4) apply_setting(L"mode", g_modes[i]);
            }
            break;
        case IDC_CB_TARGET:
            if (code == CBN_SELCHANGE) {
                int i = (int)SendDlgItemMessageW(h, IDC_CB_TARGET, CB_GETCURSEL, 0, 0);
                apply_setting(L"autotarget", i == 1 ? L"base" : L"intermediate");
            }
            break;
        case IDC_B_SAVECOUNT: {
            WCHAR v[16];
            _snwprintf(v, 15, L"%u", GetDlgItemInt(h, IDC_ED_COUNT, NULL, FALSE));
            apply_setting(L"countdown", v);
            break;
        }
        case IDC_B_CMD: {
            STARTUPINFOW si = { sizeof(si) };
            PROCESS_INFORMATION pi;
            WCHAR cl[] = L"cmd.exe /k title Image-O-Tron maintenance prompt && echo Close this window to return.";
            stop_countdown();
            if (CreateProcessW(NULL, cl, NULL, NULL, FALSE, CREATE_NEW_CONSOLE, NULL, NULL, &si, &pi)) {
                CloseHandle(pi.hProcess);
                CloseHandle(pi.hThread);
            }
            break;
        }
        case IDC_B_HIST:
            stop_countdown();
            show_history();
            break;
        case IDC_B_REFRESH:
            refresh_state();
            set_status(L"Refreshed.");
            break;
        case IDC_B_CANCEL: {
            WCHAR *r = (WCHAR *)malloc(RESP_MAX * sizeof(WCHAR));
            pipe_call(L"CANCEL", r);
            if (wcsncmp(r, L"OK", 2)) MessageBoxW(h, r, APP_TITLE, MB_ICONERROR);
            else set_status(L"Scheduled action cancelled.");
            free(r);
            refresh_state();
            break;
        }
        }
        return 0;
    }
    case WM_CLOSE:
        if (g_busy) {
            MessageBoxW(h, L"Please wait until the current action has finished.", APP_TITLE, MB_ICONINFORMATION);
            return 0;
        }
        if (g_pe) {
            int r = MessageBoxW(h, L"Close without doing anything and go to the WinPE command prompt?\n\n"
                                L"(Type 'exit' there to restart; you'll come back to this screen.)",
                                APP_TITLE, MB_YESNO | MB_ICONQUESTION);
            if (r != IDYES) return 0;
            PostQuitMessage(2);
            return 0;
        }
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        if (!g_pe) PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

static int run_gui(HINSTANCE hi)
{
    /* comctl32 v6 visual styles if available (WinPE may lack them) */
    ACTCTXW ac;
    ZeroMemory(&ac, sizeof(ac));
    ac.cbSize = sizeof(ac);
    ac.dwFlags = ACTCTX_FLAG_HMODULE_VALID | ACTCTX_FLAG_RESOURCE_NAME_VALID;
    ac.hModule = hi;
    ac.lpResourceName = MAKEINTRESOURCEW(IDR_STYLES);
    HANDLE hac = CreateActCtxW(&ac);
    ULONG_PTR cookie = 0;
    if (hac != INVALID_HANDLE_VALUE) ActivateActCtx(hac, &cookie);

    INITCOMMONCONTROLSEX icc = { sizeof(icc), ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&icc);

    HDC sdc = GetDC(NULL);
    g_dpi = GetDeviceCaps(sdc, LOGPIXELSY);
    ReleaseDC(NULL, sdc);
    g_font = CreateFontW(-S(14), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_fontB = CreateFontW(-S(14), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_fontBtn = CreateFontW(-S(13), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_banner = LoadBitmapW(hi, MAKEINTRESOURCEW(g_pe ? IDB_RED : IDB_BLUE));

    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = hi;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.hIcon = LoadIconW(hi, MAKEINTRESOURCEW(IDI_APP));
    wc.lpszClassName = L"ImageOTronWnd";
    RegisterClassExW(&wc);

    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT r = { 0, 0, S(CLIENT_W), S(CLIENT_H) };
    AdjustWindowRect(&r, style, FALSE);
    int ww = r.right - r.left, wh = r.bottom - r.top;
    int sx = GetSystemMetrics(SM_CXSCREEN), sy = GetSystemMetrics(SM_CYSCREEN);
    WCHAR title[128];
    _snwprintf(title, 127, L"%ls - %ls", APP_TITLE, g_pe ? L"Boot manager (WinPE)" : L"Steadier State");
    HWND h = CreateWindowExW(0, wc.lpszClassName, title, style,
                             max(0, (sx - ww) / 2), max(0, (sy - wh) / 2), ww, wh,
                             NULL, NULL, hi, NULL);
    ShowWindow(h, SW_SHOW);
    UpdateWindow(h);
    SetForegroundWindow(h);

    if (g_pe) {
        if (g_autoAction[0]) {
            PostMessageW(h, WM_APP_START, 0, 0);
        } else if (g_cfg.countdown > 0) {
            g_count = g_cfg.countdown;
            SetTimer(h, TIMER_COUNT, 1000, NULL);
            SendMessageW(h, WM_TIMER, TIMER_COUNT, 0);
        } else {
            set_status(L"Choose an action.");
        }
    }

    MSG msg;
    int rc = 0;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (g_count >= 0 && (msg.message == WM_KEYDOWN || msg.message == WM_LBUTTONDOWN ||
                             msg.message == WM_RBUTTONDOWN || msg.message == WM_NCLBUTTONDOWN))
            stop_countdown();
        if (!IsDialogMessageW(h, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    rc = (int)msg.wParam;
    if (hac != INVALID_HANDLE_VALUE) { DeactivateActCtx(0, cookie); ReleaseActCtx(hac); }
    return rc;
}

/* ------------------------------------------------------------------ */
/* console output for the command-line modes                           */
/* ------------------------------------------------------------------ */
static void out(const WCHAR *fmt, ...)
{
    static BOOL attached = FALSE;
    if (!attached) { AttachConsole(ATTACH_PARENT_PROCESS); attached = TRUE; }
    WCHAR b[4096];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(b, 4095, fmt, ap);
    b[4095] = 0;
    va_end(ap);
    HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD n;
    if (h && h != INVALID_HANDLE_VALUE) {
        if (!WriteConsoleW(h, b, (DWORD)wcslen(b), &n, NULL)) {
            int len = WideCharToMultiByte(CP_OEMCP, 0, b, -1, NULL, 0, NULL, NULL);
            char *a = (char *)malloc(len);
            WideCharToMultiByte(CP_OEMCP, 0, b, -1, a, len, NULL, NULL);
            WriteFile(h, a, len - 1, &n, NULL);
            free(a);
        }
    }
}

static int cli_install(BOOL install)
{
    SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_ALL_ACCESS);
    if (!scm) { out(L"Can't open the service manager (error %lu). Run elevated.\r\n", GetLastError()); return 1; }
    SC_HANDLE s = OpenServiceW(scm, SVC_NAME, SERVICE_ALL_ACCESS);
    if (s) {
        SERVICE_STATUS st;
        ControlService(s, SERVICE_CONTROL_STOP, &st);
        Sleep(1000);
        DeleteService(s);
        CloseServiceHandle(s);
        Sleep(500);
    }
    if (!install) { out(L"Service removed.\r\n"); CloseServiceHandle(scm); return 0; }

    WCHAR exe[MAX_PATH], bin[MAX_PATH + 32];
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    _snwprintf(bin, MAX_PATH + 31, L"\"%ls\" /service", exe);
    s = CreateServiceW(scm, SVC_NAME, SVC_DISPLAY, SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS,
                       SERVICE_AUTO_START, SERVICE_ERROR_NORMAL, bin, NULL, NULL, NULL, NULL, NULL);
    if (!s) { out(L"CreateService failed (error %lu).\r\n", GetLastError()); CloseServiceHandle(scm); return 1; }
    SERVICE_DESCRIPTIONW sd = { (LPWSTR)L"Lets the Image-O-Tron app schedule Steadier State rollbacks and "
                                         L"merges, and keeps the boot entries in step with the chosen mode." };
    ChangeServiceConfig2W(s, SERVICE_CONFIG_DESCRIPTION, &sd);
    StartServiceW(s, 0, NULL);
    CloseServiceHandle(s);
    CloseServiceHandle(scm);
    out(L"Service %ls installed and started.\r\n", SVC_NAME);

    /* create default settings if there are none yet */
    if (find_phy_volume()) {
        WCHAR p[MAX_PATH];
        phy_path(p, L"srsdirectives\\srs.ini");
        Config c;
        if (!file_exists(p)) { cfg_defaults(&c); cfg_save(&c); out(L"Created default srs.ini (mode=gui).\r\n"); }
        cfg_load(&c);
        detail_reset(L"install");
        bcd_apply(&c, FALSE, FALSE);
        history(L"install", L"service installed");
    } else {
        out(L"WARNING: couldn't find the Physical_Drive volume.\r\n");
    }
    return 0;
}

static int cli(int argc, WCHAR **argv)
{
    WCHAR *r = (WCHAR *)malloc(RESP_MAX * sizeof(WCHAR)), req[256];
    int rc = 0;
    const WCHAR *a = argv[1];
    if (!_wcsicmp(a, L"/install"))   return cli_install(TRUE);
    if (!_wcsicmp(a, L"/uninstall")) return cli_install(FALSE);
    if (!_wcsicmp(a, L"/status")) {
        pipe_call(L"STATUS", r);
        out(L"%ls\r\n", r);
        return wcsncmp(r, L"OK", 2) ? 1 : 0;
    }
    if (!_wcsicmp(a, L"/cancel")) {
        pipe_call(L"CANCEL", r);
        out(L"%ls\r\n", r);
        return wcsncmp(r, L"OK", 2) ? 1 : 0;
    }
    if (!_wcsicmp(a, L"/schedule") && argc >= 3) {
        BOOL shut = FALSE, now = FALSE;
        for (int i = 3; i < argc; i++) {
            if (!_wcsicmp(argv[i], L"/shutdown")) shut = TRUE;
            if (!_wcsicmp(argv[i], L"/now")) now = TRUE;
        }
        _snwprintf(req, 255, L"SCHEDULE %ls %ls %d", argv[2], shut ? L"shutdown" : L"reboot", now);
        pipe_call(req, r);
        out(L"%ls\r\n", r);
        return wcsncmp(r, L"OK", 2) ? 1 : 0;
    }
    if (!_wcsicmp(a, L"/set") && argc >= 4) {
        _snwprintf(req, 255, L"SET %ls %ls", argv[2], argv[3]);
        pipe_call(req, r);
        out(L"%ls\r\n", r);
        return wcsncmp(r, L"OK", 2) ? 1 : 0;
    }
    out(L"Image-O-Tron 11,000 - Steadier State boot manager\r\n\r\n"
        L"  srsmgr                                 desktop app\r\n"
        L"  srsmgr /status | /cancel\r\n"
        L"  srsmgr /schedule <action> [/shutdown] [/now]\r\n"
        L"      actions: rollback_inter rollback_base merge_inter merge_base promote\r\n"
        L"               rollback | merge  (= to the intermediate if any, per autotarget)\r\n"
        L"  srsmgr /set mode <gui|autorollback|direct|automerge>\r\n"
        L"  srsmgr /set autotarget <intermediate|base>\r\n"
        L"  srsmgr /set countdown <seconds, 0 = wait forever>\r\n"
        L"  srsmgr /install | /uninstall           (elevated)\r\n"
        L"  srsmgr /pe /phy D: /store <BCD path>   (WinPE boot screen)\r\n");
    free(r);
    return rc ? rc : 1;
}

/* ------------------------------------------------------------------ */
int WINAPI wWinMain(HINSTANCE hi, HINSTANCE hp, PWSTR cmd, int show)
{
    (void)hp; (void)cmd; (void)show;
    int argc = 0;
    WCHAR **argv = CommandLineToArgvW(GetCommandLineW(), &argc);

    if (argc >= 2 && !_wcsicmp(argv[1], L"/service")) {
        SERVICE_TABLE_ENTRYW t[] = { { (LPWSTR)SVC_NAME, svc_main }, { NULL, NULL } };
        StartServiceCtrlDispatcherW(t);
        return 0;
    }

    if (argc >= 2 && !_wcsicmp(argv[1], L"/pe")) {
        g_pe = TRUE;
        for (int i = 2; i + 1 < argc; i++) {
            if (!_wcsicmp(argv[i], L"/phy")) {
                wcsncpy(g_phyLetter, argv[i + 1], 2);
                g_phyLetter[2] = 0;
                _snwprintf(g_phy, MAX_PATH, L"%ls\\", g_phyLetter);
            } else if (!_wcsicmp(argv[i], L"/store")) {
                _snwprintf(g_store, MAX_PATH + 15, L"/store \"%ls\"", argv[i + 1]);
            }
        }
        if (!g_phy[0]) {
            MessageBoxW(NULL, L"Usage: srsmgr /pe /phy D: /store <BCD path>", APP_TITLE, MB_ICONERROR);
            return 2;
        }
        WCHAR d[MAX_PATH];
        phy_path(d, L"srsdirectives");
        CreateDirectoryW(d, NULL);
        cfg_load(&g_cfg);
        chain_get(&g_chain);
        if (!g_chain.image.exists) {
            MessageBoxW(NULL, L"image.vhd isn't on the Physical Drive yet.\n\n"
                        L"Run prepnewpc from the Steadier State USB stick first. Closing to the command prompt.",
                        APP_TITLE, MB_ICONERROR);
            return 2;
        }
        if (!g_chain.snap.exists) {
            wcscpy(g_autoAction, L"initial");
        } else if (_wcsicmp(g_cfg.pending, L"none") && find_act(g_cfg.pending)) {
            wcsncpy(g_autoAction, g_cfg.pending, 31);
            g_autoFromPending = TRUE;
        } else {
            const WCHAR *aa = auto_action(&g_cfg, &g_chain);
            if (aa) wcscpy(g_autoAction, aa);
            else if (!_wcsicmp(g_cfg.mode, L"direct")) wcscpy(g_autoAction, L"continue");
        }
        return run_gui(hi);
    }

    if (argc >= 2) return cli(argc, argv);
    return run_gui(hi);
}
