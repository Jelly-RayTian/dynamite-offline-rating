#include "orp_engine.h"
#include <math.h>
#include <stdlib.h>

double orp_accuracy(int p, int g, int m) {
    long long n = (long long)p + g + m;
    if (n <= 0) return 0.0;
    return ((double)p + g / 2.0) / (double)n;
}

double orp_full_r(double d) {
    return (double)(long long)(pow(d, 3.0) - pow(d, 2.8));
}

static double r_goodbird(double d, int p, int g, int m) {
    double acc = orp_accuracy(p, g, m);
    double a = acc * 50.0;
    double b = pow(acc, 8.0) * pow(d, 3.0) - pow(d, 2.8);
    double v = a > b ? a : b;
    return (double)(long long)v;  // truncate toward zero
}

double orp_chart_rating(int algo, double d, int p, int g, int m) {
    (void)algo;   // only one formula is shipped
    return r_goodbird(d, p, g, m);
}

static int cmp_desc(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x < y) - (x > y);
}

int orp_overall_rating(const double *ratings, int count, int top_n) {
    if (count <= 0 || top_n <= 0) return 0;
    double *tmp = (double *)malloc(sizeof(double) * (size_t)count);
    if (!tmp) return 0;
    for (int i = 0; i < count; i++) tmp[i] = ratings[i];
    qsort(tmp, (size_t)count, sizeof(double), cmp_desc);
    double sum = 0.0;
    for (int i = 0; i < count && i < top_n; i++) sum += tmp[i];
    free(tmp);
    return (int)floor(sum + 0.5);
}
