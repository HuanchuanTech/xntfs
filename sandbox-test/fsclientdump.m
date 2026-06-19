#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <string.h>

static void dumpClass(const char *name) {
    Class c = objc_getClass(name);
    if (!c) { printf("(class %s not found)\n", name); return; }
    unsigned int n = 0;
    printf("== %s — instance methods ==\n", name);
    Method *m = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++) printf("  -%s\n", sel_getName(method_getName(m[i])));
    free(m);
    printf("== %s — class methods ==\n", name);
    Method *cm = class_copyMethodList(object_getClass(c), &n);
    for (unsigned i = 0; i < n; i++) printf("  +%s\n", sel_getName(method_getName(cm[i])));
    free(cm);
}

int main(void) {
    @autoreleasepool {
        dumpClass("FSClient");
        printf("\n== any class with a mount+volume/resource/single selector ==\n");
        unsigned int total = 0;
        Class *all = objc_copyClassList(&total);
        for (unsigned i = 0; i < total; i++) {
            Class c = all[i];
            const char *cn = class_getName(c);
            unsigned int n = 0;
            Method *m = class_copyMethodList(c, &n);
            for (unsigned j = 0; j < n; j++) {
                const char *s = sel_getName(method_getName(m[j]));
                if (strcasestr(s, "mount") &&
                    (strcasestr(s, "volume") || strcasestr(s, "resource") || strcasestr(s, "single") || strcasestr(s, "bundle")))
                    printf("  %s : -%s\n", cn, s);
            }
            free(m);
        }
        free(all);
    }
    return 0;
}
