/*
 * Stepover's per-program compatibility plug-in: an open replacement for CrossOver's closed
 * cxcompatdb.so. CrossOver's Wine (dlls/ntdll/unix/loader.c, "CW Hack 24067") dlopens
 * <ntdll dir>/cxcompatdb.so in every process, right after ntdll is loaded and before the program
 * itself starts. Our constructor looks up the program in the bottle's stepover-compat.conf and
 *   - puts its graphics backend's DLL folder (D3DMetal, DXMT, DXVK) first on the DLL path with
 *     ntdll's exported prepend_dll_path(), the same export CrossOver's plug-in uses,
 *   - sets CX_ACTIVE_GRAPHICS_BACKEND, which win32u reads (WDDM 2.7 caps for D3DMetal),
 *   - sets the program's extra environment variables,
 *   - sets DLL overrides (`dll = ddraw=n,b`, WINEDLLOVERRIDES syntax) with ntdll's exported
 *     add_load_order_override(), as CrossOver's plug-in does,
 *   - appends extra arguments to its command line (for programs started by other programs, such
 *     as Steam's steamwebhelper.exe, whose command line we don't control; 64-bit programs only).
 *
 * Config: $STEPOVER_COMPAT, else $WINEPREFIX/stepover-compat.conf. INI sections are program file
 * names or full Windows paths (case-insensitive), or "*" for the default:
 *     [*]
 *     backend = d3dmetal
 *     [lanoire.exe]
 *     backend = dxmt
 *     env = DXMT_LOG_LEVEL=none
 *     [steamwebhelper.exe]
 *     args = --in-process-gpu
 * Backend folders default to <runtime>/lib/{d3dmetal/wine,dxmt,dxvk}; STEPOVER_D3DMETAL_DIR,
 * STEPOVER_DXMT_DIR and STEPOVER_DXVK_DIR override them. STEPOVER_COMPAT_DEBUG=1 logs to stderr.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <sys/stat.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winternl.h"

extern void prepend_dll_path( const char *path );  /* exported by CrossOver's ntdll.so */
extern void add_load_order_override( const WCHAR *entry );  /* WINEDLLOVERRIDES syntax; ntdll copies it */

#define MAX_ENV 32
#define MAX_ARGS 8
#define MAX_DLLS 32

struct program
{
    char backend[32];
    char *env[MAX_ENV];
    int env_count;
    char *args[MAX_ARGS];
    int args_count;
    char *dlls[MAX_DLLS];
    int dlls_count;
};

static int debug;

static void say( const char *fmt, ... )
{
    va_list args;
    if (!debug) return;
    va_start( args, fmt );
    fputs( "stepover-compat: ", stderr );
    vfprintf( stderr, fmt, args );
    fputc( '\n', stderr );
    va_end( args );
}

/* The running program's file name (file_only) or full Windows path, lowercased UTF-8, from the PEB's
 * ImagePathName. Sections in the config match either. */
static int image_path( int file_only, char *out, size_t size )
{
    RTL_USER_PROCESS_PARAMETERS *params = NtCurrentTeb()->Peb->ProcessParameters;
    const WCHAR *path, *name;
    size_t len, i, pos = 0;

    if (!params || !params->ImagePathName.Buffer) return 0;
    path = params->ImagePathName.Buffer;
    len = params->ImagePathName.Length / sizeof(WCHAR);
    name = path;
    if (file_only) { for (i = 0; i < len; i++) if (path[i] == '\\' || path[i] == '/') name = path + i + 1; }
    else if (len >= 4 && path[0] == '\\' && (path[1] == '?' || path[1] == '\\') && path[2] == '?' && path[3] == '\\') name = path + 4;
    for (; name < path + len && pos + 4 < size; name++)
    {
        WCHAR c = *name;
        if (c < 0x80) out[pos++] = tolower( c );
        else if (c < 0x800) { out[pos++] = 0xc0 | (c >> 6); out[pos++] = 0x80 | (c & 0x3f); }
        else { out[pos++] = 0xe0 | (c >> 12); out[pos++] = 0x80 | ((c >> 6) & 0x3f); out[pos++] = 0x80 | (c & 0x3f); }
    }
    out[pos] = 0;
    return pos > 0;
}

static char *trim( char *s )
{
    char *end;
    while (isspace( (unsigned char)*s )) s++;
    end = s + strlen( s );
    while (end > s && isspace( (unsigned char)end[-1] )) *--end = 0;
    return s;
}

/* Fills *prog from the "*" section, then lets the program's own section override it. */
static int read_config( const char *path, const char *name, const char *full, struct program *prog )
{
    char line[4096], section[1024] = "";
    int found = 0, in_default = 0, in_match = 0;
    FILE *f = fopen( path, "r" );

    if (!f) return 0;
    while (fgets( line, sizeof(line), f ))
    {
        char *s = trim( line ), *eq, *key, *value;

        if (!*s || *s == '#' || *s == ';') continue;
        if (*s == '[')
        {
            char *close = strchr( s, ']' );
            if (!close) continue;
            *close = 0;
            snprintf( section, sizeof(section), "%s", trim( s + 1 ));
            in_default = !strcmp( section, "*" );
            in_match = !in_default && (!strcasecmp( section, name ) || (*full && !strcasecmp( section, full )));
            found |= in_match;
            continue;
        }
        if (!in_default && !in_match) continue;
        if (!(eq = strchr( s, '=' ))) continue;
        *eq = 0;
        key = trim( s );
        value = trim( eq + 1 );
        if (!strcmp( key, "backend" ))
        {
            /* the program's own section wins over the default whatever the file order */
            if (in_match || !found) snprintf( prog->backend, sizeof(prog->backend), "%s", value );
        }
        else if (!strcmp( key, "env" ) && strchr( value, '=' ) && prog->env_count < MAX_ENV)
            prog->env[prog->env_count++] = strdup( value );
        else if (!strcmp( key, "args" ) && in_match && *value && prog->args_count < MAX_ARGS)
            prog->args[prog->args_count++] = strdup( value );  /* never from [*]: every process would get them */
        else if (!strcmp( key, "dll" ) && in_match && strchr( value, '=' ) && prog->dlls_count < MAX_DLLS)
            prog->dlls[prog->dlls_count++] = strdup( value );
    }
    fclose( f );
    return found;
}

static int arg_boundary( WCHAR c ) { return c == ' ' || c == '\t' || c == '"' || c == '='; }

static size_t wlen( const WCHAR *s ) { size_t n = 0; while (s[n]) n++; return n; }

/* UTF-8 to UTF-16 (BMP), into out (room for size WCHARs incl. the NUL); returns the length. */
static size_t utf8_to_wide( const char *in, WCHAR *out, size_t size )
{
    const unsigned char *s = (const unsigned char *)in;
    size_t n = 0;
    while (*s && n + 1 < size)
    {
        if (*s < 0x80) out[n++] = *s++;
        else if ((*s & 0xe0) == 0xc0 && s[1]) { out[n++] = (WCHAR)(((s[0] & 0x1f) << 6) | (s[1] & 0x3f)); s += 2; }
        else if ((*s & 0xf0) == 0xe0 && s[1] && s[2]) { out[n++] = (WCHAR)(((s[0] & 0x0f) << 12) | ((s[1] & 0x3f) << 6) | (s[2] & 0x3f)); s += 3; }
        else { out[n++] = '?'; s++; while ((*s & 0xc0) == 0x80) s++; }
    }
    out[n] = 0;
    return n;
}

/* Sets NAME=value in the Windows environment block as well. Windows programs read that block;
 * setenv() alone only reaches Mac-side code such as Metal, because Wine built the block before this
 * plug-in loaded. PE ntdll copies the block by EnvironmentSize later (init_user_process_params), so
 * a replaced block is what the program gets. 64-bit programs only, like append_args. */
static void set_windows_env( const char *name, const char *value )
{
    RTL_USER_PROCESS_PARAMETERS *params = NtCurrentTeb()->Peb->ProcessParameters;
    const WCHAR *env = params->Environment, *p;
    size_t name_len = strlen( name ), value_size = strlen( value ) + 1, len, i;
    WCHAR *buf, *out;

    if (NtCurrentTeb()->WowTebOffset || !env) return;
    for (p = env; *p; p += wlen( p ) + 1);
    if (!(buf = calloc( (size_t)(p - env) + name_len + value_size + 2, sizeof(WCHAR) ))) return;
    out = buf;
    for (p = env; *p; p += len + 1)
    {
        len = wlen( p );
        for (i = 0; i < name_len && p[i] && toupper( p[i] < 0x80 ? p[i] : 0 ) == toupper( (unsigned char)name[i] ); i++);
        if (i == name_len && p[i] == '=') continue;  /* the old value */
        memcpy( out, p, (len + 1) * sizeof(WCHAR) );
        out += len + 1;
    }
    out += utf8_to_wide( name, out, name_len + 1 );
    *out++ = '=';
    out += utf8_to_wide( value, out, value_size ) + 1;
    *out++ = 0;  /* the block ends with an empty string */
    params->Environment = buf;
    params->EnvironmentSize = (SIZE_T)(out - buf) * sizeof(WCHAR);
}

/* Appends " <args>" (raw ASCII text) to the PEB's command line unless it is already there as whole
 * words. PE ntdll copies the parameters into its own block later (init_user_process_params), so
 * programs see the change; our buffer is simply never freed. 64-bit programs only: for WoW64 the
 * 32-bit copy of the parameters is built before this plug-in loads. */
static void append_args( const char *name, const char *args )
{
    UNICODE_STRING *cmd = &NtCurrentTeb()->Peb->ProcessParameters->CommandLine;
    size_t len = cmd->Length / sizeof(WCHAR), add = strlen( args ), i, j;
    WCHAR *buf;

    if (NtCurrentTeb()->WowTebOffset)
    {
        say( "%s: 32-bit program, not appending %s", name, args );
        return;
    }
    while (len && !cmd->Buffer[len - 1]) len--;  /* a length that counts the terminating NUL */
    for (i = 0; i + add <= len; i++)
    {
        for (j = 0; j < add && cmd->Buffer[i + j] == (unsigned char)args[j]; j++);
        if (j == add && (!i || arg_boundary( cmd->Buffer[i - 1] )) && (i + add == len || arg_boundary( cmd->Buffer[i + add] )))
            return;
    }
    if (len + 1 + add >= UNICODE_STRING_MAX_CHARS)
    {
        say( "%s: command line too long to append %s", name, args );
        return;
    }
    if (!(buf = calloc( len + add + 2, sizeof(WCHAR) ))) return;
    memcpy( buf, cmd->Buffer, len * sizeof(WCHAR) );
    buf[len] = ' ';
    for (i = 0; i < add; i++) buf[len + 1 + i] = (unsigned char)args[i];
    cmd->Buffer = buf;
    cmd->Length = (USHORT)((len + 1 + add) * sizeof(WCHAR));  /* fits: checked against UNICODE_STRING_MAX_CHARS */
    cmd->MaximumLength = (USHORT)(cmd->Length + sizeof(WCHAR));
    say( "%s: appended %s to the command line", name, args );
}

static int is_dir( const char *path )
{
    struct stat st;
    return !stat( path, &st ) && S_ISDIR( st.st_mode );
}

/* <runtime>/lib, from this plug-in's own path: <runtime>/lib/wine/x86_64-unix/cxcompatdb.so */
static void runtime_lib_dir( char *out, size_t size )
{
    Dl_info info;
    char buf[PATH_MAX], lib[PATH_MAX];

    out[0] = 0;
    if (!dladdr( (void *)runtime_lib_dir, &info ) || !info.dli_fname) return;
    snprintf( buf, sizeof(buf), "%s", info.dli_fname );
    snprintf( lib, sizeof(lib), "%s/../..", dirname( buf ));
    if (!realpath( lib, buf )) snprintf( buf, sizeof(buf), "%s", lib );
    snprintf( out, size, "%s", buf );
}

static const char *backend_dir( const char *backend, char *out, size_t size )
{
    const char *var = NULL, *sub = NULL, *env;
    char lib[PATH_MAX];

    if (!strcmp( backend, "d3dmetal" )) { var = "STEPOVER_D3DMETAL_DIR"; sub = "d3dmetal/wine"; }
    else if (!strcmp( backend, "dxmt" )) { var = "STEPOVER_DXMT_DIR"; sub = "dxmt"; }
    else if (!strcmp( backend, "dxvk" )) { var = "STEPOVER_DXVK_DIR"; sub = "dxvk"; }
    else return NULL;

    if ((env = getenv( var )) && *env) snprintf( out, size, "%s", env );
    else
    {
        runtime_lib_dir( lib, sizeof(lib) );
        if (!lib[0]) return NULL;
        snprintf( out, size, "%s/%s", lib, sub );
    }
    return out;
}

__attribute__((constructor))
static void stepover_compat_init( void )
{
    struct program prog;
    char name[256], full[1024], conf[PATH_MAX], dir[PATH_MAX], arch_dir[PATH_MAX + 32];
    const char *path = getenv( "STEPOVER_COMPAT" ), *prefix = getenv( "WINEPREFIX" );
    int i;

    memset( &prog, 0, sizeof(prog) );
    debug = getenv( "STEPOVER_COMPAT_DEBUG" ) && *getenv( "STEPOVER_COMPAT_DEBUG" ) == '1';
    if (!image_path( 1, name, sizeof(name) )) return;
    if (!image_path( 0, full, sizeof(full) )) full[0] = 0;
    if (!path || !*path)
    {
        if (!prefix || !*prefix) return;
        snprintf( conf, sizeof(conf), "%s/stepover-compat.conf", prefix );
        path = conf;
    }
    read_config( path, name, full, &prog );
    if (!prog.backend[0]) strcpy( prog.backend, "wined3d" );

    for (i = 0; i < prog.env_count; i++)
    {
        char *eq = strchr( prog.env[i], '=' );
        *eq = 0;
        setenv( prog.env[i], eq + 1, 1 );
        set_windows_env( prog.env[i], eq + 1 );
        say( "%s: %s=%s", name, prog.env[i], eq + 1 );
        free( prog.env[i] );
    }
    for (i = 0; i < prog.dlls_count; i++)
    {
        WCHAR entry[256];
        size_t j, len = strlen( prog.dlls[i] );
        if (len < sizeof(entry) / sizeof(entry[0]))
        {
            for (j = 0; j <= len; j++) entry[j] = (unsigned char)prog.dlls[i][j];
            add_load_order_override( entry );
            say( "%s: DLL override %s", name, prog.dlls[i] );
        }
        free( prog.dlls[i] );
    }
    for (i = 0; i < prog.args_count; i++)
    {
        append_args( name, prog.args[i] );
        free( prog.args[i] );
    }

    if (strcmp( prog.backend, "wined3d" ))
    {
        if (!backend_dir( prog.backend, dir, sizeof(dir) ))
        {
            say( "%s: unknown backend %s, using wined3d", name, prog.backend );
            strcpy( prog.backend, "wined3d" );
        }
        else
        {
            snprintf( arch_dir, sizeof(arch_dir), "%s/x86_64-windows", dir );
            if (!is_dir( arch_dir ))
            {
                say( "%s: %s is missing, using wined3d", name, arch_dir );
                strcpy( prog.backend, "wined3d" );
            }
            else prepend_dll_path( strdup( dir ));  /* ntdll keeps the pointer */
        }
    }
    setenv( "CX_ACTIVE_GRAPHICS_BACKEND", prog.backend, 1 );
    say( "%s: backend %s%s%s", name, prog.backend, strcmp( prog.backend, "wined3d" ) ? " from " : "",
         strcmp( prog.backend, "wined3d" ) ? dir : "" );
}
