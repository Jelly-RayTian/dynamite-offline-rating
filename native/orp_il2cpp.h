// Minimal runtime reflection on the game's IL2CPP runtime (exported il2cpp_* API).
#ifndef ORP_IL2CPP_H
#define ORP_IL2CPP_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Both return 1 on success, 0 on failure (API not ready, class/field missing).
// `cls` is a top-level class in Assembly-CSharp with the empty namespace.
int orp_il2cpp_static_string(const char *cls, const char *field, char *out, size_t cap);
int orp_il2cpp_static_int(const char *cls, const char *field, int *out);
// Converts a managed System.String* (as received in a hooked function's argument) to UTF-8.
// Returns 1 on success (out is "" for a null string), 0 on failure.
int orp_il2cpp_string_to_utf8(void *managed_string, char *out, size_t cap);
// Reads an object-reference instance field (e.g. UsernameField) of a managed object; NULL if missing.
void *orp_il2cpp_get_obj_field(void *obj, const char *field);
// Calls an instance method by name (argc arguments; reference-type arguments are passed as the object pointer).
// *ok = 0 when the method is missing or threw. Returns the managed return value (or NULL).
void *orp_il2cpp_call(void *obj, const char *method, int argc, void **args, int *ok);
// Calls obj.method(string) (e.g. an Action<string> delegate's "Invoke"). Returns 1 if it ran without throwing.
int orp_il2cpp_invoke_with_string(void *obj, const char *method, const char *utf8);
// UnityEngine.UI.InputField text. Return 1 on success.
int orp_il2cpp_input_get_text(void *input_field, char *out, size_t cap);
int orp_il2cpp_input_set_text(void *input_field, const char *utf8);
// Name of the object's class ("" if unknown).
const char *orp_il2cpp_class_name_of(void *obj);
// Calls the game's own `Encrypting.DecryptBytes(byte[])` (what it uses for every *.rnx asset) on `in`.
// Returns a malloc'd buffer (caller frees) or NULL on failure. Must be called on the game's (main) thread.
unsigned char *orp_il2cpp_decrypt_bytes(const unsigned char *in, size_t n, size_t *out_len);
// Sets UserManagement.Local.ThisUser.username. 1 = changed, 2 = already that name, 0 = not available yet.
int orp_il2cpp_set_user_name(const char *name);

// Writes `r` into UserManagement.Local.ThisUser.RThisMonth (the value every screen shows as the
// player's R). Returns 1 = changed, 2 = already that value, 0 = user object not available yet.
int orp_il2cpp_set_user_r(int r);
#ifdef __cplusplus
}
#endif
#endif
