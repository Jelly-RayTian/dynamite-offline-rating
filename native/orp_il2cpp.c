#include "orp_il2cpp.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void *(*fn_domain_get)(void);
typedef void **(*fn_domain_get_assemblies)(void *, size_t *);
typedef void *(*fn_assembly_get_image)(void *);
typedef const char *(*fn_image_get_name)(void *);
typedef void *(*fn_class_from_name)(void *, const char *, const char *);
typedef void *(*fn_class_get_field)(void *, const char *);
typedef void (*fn_static_get)(void *, void *);
typedef const uint16_t *(*fn_string_chars)(void *);
typedef int32_t (*fn_string_length)(void *);
typedef void *(*fn_object_class)(void *);
typedef void *(*fn_string_new)(const char *);
typedef void *(*fn_array_new)(void *, uintptr_t);
typedef uintptr_t (*fn_array_length)(void *);
typedef void *(*fn_get_corlib)(void);
typedef void *(*fn_get_method)(void *, const char *, int);
typedef void *(*fn_invoke)(void *, void *, void **, void **);
typedef const char *(*fn_class_name)(void *);
typedef size_t (*fn_field_offset)(void *);
typedef void (*fn_field_get)(void *, void *, void *);

static struct {
    fn_domain_get domain_get;
    fn_domain_get_assemblies get_assemblies;
    fn_assembly_get_image assembly_image;
    fn_image_get_name image_name;
    fn_class_from_name class_from_name;
    fn_class_get_field class_field;
    fn_static_get static_get;
    fn_string_chars str_chars;
    fn_string_length str_len;
    fn_object_class object_class;
    fn_string_new string_new;
    fn_array_new array_new;
    fn_array_length array_length;
    fn_get_corlib get_corlib;
    fn_get_method get_method;
    fn_invoke invoke;
    fn_class_name class_name;
    fn_field_offset field_offset;
    fn_field_get field_get;
    void *image;  // Assembly-CSharp
    int ready;
} A;

static int init_api(void) {
    if (A.ready) return 1;
#define LOAD(f, n) do { A.f = dlsym(RTLD_DEFAULT, n); if (!A.f) return 0; } while (0)
    LOAD(domain_get, "il2cpp_domain_get");
    LOAD(get_assemblies, "il2cpp_domain_get_assemblies");
    LOAD(assembly_image, "il2cpp_assembly_get_image");
    LOAD(image_name, "il2cpp_image_get_name");
    LOAD(class_from_name, "il2cpp_class_from_name");
    LOAD(class_field, "il2cpp_class_get_field_from_name");
    LOAD(static_get, "il2cpp_field_static_get_value");
    LOAD(str_chars, "il2cpp_string_chars");
    LOAD(str_len, "il2cpp_string_length");
    LOAD(object_class, "il2cpp_object_get_class");
    LOAD(string_new, "il2cpp_string_new");
    LOAD(array_new, "il2cpp_array_new");
    LOAD(array_length, "il2cpp_array_length");
    LOAD(get_corlib, "il2cpp_get_corlib");
    LOAD(get_method, "il2cpp_class_get_method_from_name");
    LOAD(invoke, "il2cpp_runtime_invoke");
    LOAD(class_name, "il2cpp_class_get_name");
    LOAD(field_offset, "il2cpp_field_get_offset");
    LOAD(field_get, "il2cpp_field_get_value");
#undef LOAD
    void *dom = A.domain_get();
    if (!dom) return 0;
    size_t n = 0;
    void **as = A.get_assemblies(dom, &n);
    for (size_t i = 0; as && i < n; i++) {
        void *img = A.assembly_image(as[i]);
        const char *nm = img ? A.image_name(img) : NULL;
        if (nm && strcmp(nm, "Assembly-CSharp.dll") == 0) { A.image = img; break; }
    }
    if (!A.image) return 0;
    A.ready = 1;
    return 1;
}

static void *find_field(const char *cls, const char *field) {
    if (!init_api()) return NULL;
    void *k = A.class_from_name(A.image, "", cls);
    if (!k) return NULL;
    return A.class_field(k, field);
}

int orp_il2cpp_static_int(const char *cls, const char *field, int *out) {
    void *f = find_field(cls, field);
    if (!f) return 0;
    int32_t v = 0;
    A.static_get(f, &v);
    *out = v;
    return 1;
}

static int utf16_to_utf8(const uint16_t *u, int32_t len, char *out, size_t cap) {
    size_t o = 0;
    for (int32_t i = 0; i < len; i++) {
        uint32_t c = u[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len && u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + (u[++i] - 0xDC00);
        }
        char tmp[4]; int n;
        if (c < 0x80) { tmp[0] = (char)c; n = 1; }
        else if (c < 0x800) { tmp[0] = (char)(0xC0 | (c >> 6)); tmp[1] = (char)(0x80 | (c & 0x3F)); n = 2; }
        else if (c < 0x10000) { tmp[0] = (char)(0xE0 | (c >> 12)); tmp[1] = (char)(0x80 | ((c >> 6) & 0x3F)); tmp[2] = (char)(0x80 | (c & 0x3F)); n = 3; }
        else { tmp[0] = (char)(0xF0 | (c >> 18)); tmp[1] = (char)(0x80 | ((c >> 12) & 0x3F)); tmp[2] = (char)(0x80 | ((c >> 6) & 0x3F)); tmp[3] = (char)(0x80 | (c & 0x3F)); n = 4; }
        if (o + (size_t)n + 1 > cap) break;
        memcpy(out + o, tmp, (size_t)n);
        o += (size_t)n;
    }
    out[o] = 0;
    return 1;
}

int orp_il2cpp_string_to_utf8(void *s, char *out, size_t cap) {
    if (cap == 0) return 0;
    out[0] = 0;
    if (!s) return 1;
    if (!init_api()) return 0;
    int32_t len = A.str_len(s);
    const uint16_t *u = A.str_chars(s);
    if (!u || len < 0 || len > 4096) return 0;
    return utf16_to_utf8(u, len, out, cap);
}

int orp_il2cpp_static_string(const char *cls, const char *field, char *out, size_t cap) {
    if (cap == 0) return 0;
    out[0] = 0;
    void *f = find_field(cls, field);
    if (!f) return 0;
    void *s = NULL;
    A.static_get(f, &s);
    return orp_il2cpp_string_to_utf8(s, out, cap);
}

void *orp_il2cpp_get_obj_field(void *obj, const char *field) {
    if (!obj || !init_api()) return NULL;
    void *k = A.object_class(obj);
    void *f = k ? A.class_field(k, field) : NULL;
    if (!f) return NULL;
    void *v = NULL;
    A.field_get(obj, f, &v);
    return v;
}

void *orp_il2cpp_call(void *obj, const char *method, int argc, void **args, int *ok) {
    if (ok) *ok = 0;
    if (!obj || !init_api()) return NULL;
    void *k = A.object_class(obj);
    void *mi = k ? A.get_method(k, method, argc) : NULL;
    if (!mi) return NULL;
    void *exc = NULL;
    void *ret = A.invoke(mi, obj, args, &exc);
    if (ok) *ok = exc == NULL;
    return exc ? NULL : ret;
}

int orp_il2cpp_invoke_with_string(void *obj, const char *method, const char *utf8) {
    if (!obj || !init_api()) return 0;
    void *args[1] = { A.string_new(utf8) };
    int ok = 0;
    orp_il2cpp_call(obj, method, 1, args, &ok);
    return ok;
}

#define ORP_ARRAY_DATA_OFFSET 0x20   /* sizeof(Il2CppArray) on 64-bit: klass, monitor, bounds, max_length */

unsigned char *orp_il2cpp_decrypt_bytes(const unsigned char *in, size_t n, size_t *out_len) {
    if (out_len) *out_len = 0;
    if (!in || !n || !init_api()) return NULL;
    void *k = A.class_from_name(A.image, "", "Encrypting");
    void *mi = k ? A.get_method(k, "DecryptBytes", 1) : NULL;
    void *corlib = A.get_corlib();
    void *byteClass = corlib ? A.class_from_name(corlib, "System", "Byte") : NULL;
    if (!mi || !byteClass) return NULL;
    void *arr = A.array_new(byteClass, n);
    if (!arr || A.array_length(arr) != n) return NULL;
    memcpy((uint8_t *)arr + ORP_ARRAY_DATA_OFFSET, in, n);
    void *args[1] = { arr };
    void *exc = NULL;
    void *ret = A.invoke(mi, NULL, args, &exc);
    if (exc || !ret) return NULL;
    uintptr_t len = A.array_length(ret);
    if (len == 0 || len > (64u << 20)) return NULL;
    unsigned char *out = (unsigned char *)malloc(len);
    if (!out) return NULL;
    memcpy(out, (uint8_t *)ret + ORP_ARRAY_DATA_OFFSET, len);
    if (out_len) *out_len = len;
    return out;
}

int orp_il2cpp_input_get_text(void *input, char *out, size_t cap) {
    int ok = 0;
    void *s = orp_il2cpp_call(input, "get_text", 0, NULL, &ok);
    if (!ok) { if (cap) out[0] = 0; return 0; }
    return orp_il2cpp_string_to_utf8(s, out, cap);
}

int orp_il2cpp_input_set_text(void *input, const char *utf8) {
    if (!input || !init_api()) return 0;
    void *str = A.string_new(utf8);
    void *args[1] = { str };
    int ok = 0;
    orp_il2cpp_call(input, "set_text", 1, args, &ok);
    return ok;
}

const char *orp_il2cpp_class_name_of(void *obj) {
    if (!obj || !init_api()) return "";
    void *k = A.object_class(obj);
    const char *n = k ? A.class_name(k) : NULL;
    return n ? n : "";
}

// UserManagement.Local.ThisUser (a UserManagement.UserDAO*), or NULL while it does not exist yet.
static void *current_user(void) {
    if (!init_api()) return NULL;
    void *k = A.class_from_name(A.image, "", "UserManagement");
    if (!k) return NULL;
    void *fLocal = A.class_field(k, "Local");
    void *fUser = A.class_field(k, "ThisUser");
    if (!fLocal || !fUser) return NULL;
    void *local = NULL;
    A.static_get(fLocal, &local);
    if (!local) return NULL;
    void *user = NULL;
    A.field_get(local, fUser, &user);
    return user;
}

int orp_il2cpp_set_user_name(const char *name) {
    void *user = current_user();
    if (!user) return 0;
    void *uk = A.object_class(user);
    void *f = uk ? A.class_field(uk, "username") : NULL;
    if (!f) return 0;
    void **slot = (void **)((uint8_t *)user + A.field_offset(f));
    char cur[256];
    if (orp_il2cpp_string_to_utf8(*slot, cur, sizeof cur) && strcmp(cur, name) == 0) return 2;
    void *str = A.string_new(name);
    if (!str) return 0;
    *slot = str;   // plain pointer store: the Boehm collector used by this build needs no write barrier
    return 1;
}

int orp_il2cpp_set_user_r(int r) {
    void *user = current_user();
    if (!user) return 0;
    void *uk = A.object_class(user);
    void *fR = uk ? A.class_field(uk, "RThisMonth") : NULL;
    if (!fR) return 0;
    // Nullable<int> layout in this build (verified from Nullable<int>.GetValueOrDefault, which does
    // `ldrb w8,[x0,#4]` for hasValue and `ldr w1,[x0]` for value): int value @0, bool has_value @4.
    uint8_t *p = (uint8_t *)user + A.field_offset(fR);
    int32_t cur = *(int32_t *)p;
    if (p[4] == 1 && cur == r) return 2;
    *(int32_t *)p = r;
    *(int32_t *)(p + 4) = 1;
    return 1;
}
