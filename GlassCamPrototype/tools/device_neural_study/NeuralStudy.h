#include "hncs_c.h"
#include "hncs_spatial.h"
#include "ffcs_c.h"
#ifdef __cplusplus
extern "C" {
#endif
const char *neural_study_prepare(const char *root, const char *model, int units, int backend);
const char *neural_study_stats(int reset);
const char *neural_study_dense(int iterations, const char *output);
const char *neural_study_error(void);
int neural_study_backend(void);
#ifdef __cplusplus
}
#endif
