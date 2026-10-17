#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void* hdr_metric_create(void);
int hdr_metric_add(void* state,const float* reference_rgba,const float* actual_rgba,size_t pixels);
int hdr_metric_finish(void* state,double* values,size_t count);
void hdr_metric_destroy(void* state);
#ifdef __cplusplus
}
#endif
