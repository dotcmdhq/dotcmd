/* Build-time resource embedder. Uses only the platform C library. */
#include <stdio.h>
#include <ctype.h>

int main(int argc, char** argv) {
    if (argc != 4) { fprintf(stderr, "usage: embed INPUT OUTPUT SYMBOL\n"); return 2; }
    for (const char* c = argv[3]; *c; ++c) {
        if (!(isalnum((unsigned char)*c) || *c == '_')) return 2;
    }
    FILE* in = fopen(argv[1], "rb");
    if (!in) { perror(argv[1]); return 1; }
    FILE* out = fopen(argv[2], "wb");
    if (!out) { perror(argv[2]); fclose(in); return 1; }
    fprintf(out, "/* Generated; do not edit. */\nstatic const unsigned char %s[] = {\n", argv[3]);
    int byte, count = 0;
    while ((byte = fgetc(in)) != EOF) {
        fprintf(out, "0x%02x,", byte);
        if (++count % 16 == 0) fputc('\n', out);
    }
    fprintf(out, "\n};\n");
    int failed = ferror(in) || ferror(out);
    if (fclose(in)) failed = 1;
    if (fclose(out)) failed = 1;
    return failed ? 1 : 0;
}
