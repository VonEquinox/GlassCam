#ifndef GLASSCAM_F5_C_H
#define GLASSCAM_F5_C_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {double lower,upper,kappa,read_sigma,uniform_probability;uint32_t kind;} F5LikelihoodEvent;
typedef struct {double nll,score,curvature,probability;} F5LikelihoodValue;
int f5_pg_event(F5LikelihoodEvent event,double mean,F5LikelihoodValue *out);
typedef struct {const float *rgba;uint32_t width,height;double pixel_size;} F5GuideInput;
typedef struct {double affine[6],hypotheses[6],ambiguity,cycle_error;} F5AlignmentValue;
int f5_align(const F5GuideInput *five,const double *timestamps,double minimum_sharpness,int *reference,F5AlignmentValue *out);
typedef struct {double shift[2],cycle_error,maximum_std,residual,normalized_correlation;uint64_t samples;int reliable;} F5LocalTranslation;
int f5_align_local(F5GuideInput input,F5GuideInput reference,double maximum_shift,double maximum_std,F5LocalTranslation *out);
int f5_reference_sample(const double *coefficients,int width,int height,int scale,
                        double x,double y,int channel,double *value,double *dx,double *dy);
typedef struct {double x,y,gain,mean,dx,dy,curvature;uint32_t color,phase,frame,kind;} F5InformationSample;
int f5_reference_limit_direction(const double *coefficients,const double *direction,double *output,
    int width,int height,int scale,const F5InformationSample *points,size_t count);
typedef struct {double minimum,condition,short_information;int motion_rank;} F5InformationResult;
int f5_information(const F5InformationSample *samples,size_t count,double noise_scale,int reference,F5InformationResult *result);
typedef struct {
    double x,y,lower,upper,exposure,eta,kappa,read_sigma,uniform_probability;
    uint32_t color,phase,frame,kind;
} F5Observation;
int f5_reference_evaluate(const F5Observation *events,size_t event_count,const double *coefficients,const double *direction,
    const double *translations,int width,int height,int scale,int reference,double sigma,double lambda_y,double lambda_c,double pi0,
    double tau,double *objective,double *gradient,double *diagonal,double *normal);
int f5_reference_evaluate_guided(const F5Observation *events,size_t event_count,const double *coefficients,const double *direction,
    const double *translations,int width,int height,int scale,int reference,double sigma,double lambda_y,double lambda_c,double pi0,
    double tau,const double *rgb_axes,const double *color_confidence,const double *luminance_scale,
    double *objective,double *gradient,double *diagonal,double *normal);
typedef struct {
    int width,height,reference,baseline,max_cycles,block_size,geometry_rounds;
    double lambda_y,lambda_c,lambda_motion,pi0,objective_tolerance,gradient_tolerance;
} F5ReferenceOptions;
typedef struct {
    int cycles,native_cycles,objective_count;
    double gradient,motion_gradient,objectives[50];
    char stop[32],native_stop[32];
} F5ReferenceReport;
/* B1/native interpolation and B5/FP64 are computational controls, not ground
   truth. Optional translations are an explicitly labelled oracle-motion test. */
int f5_reference_reconstruct(const F5Observation *events,size_t event_count,const double *translations,
    F5ReferenceOptions options,double *rgb,size_t rgb_capacity,F5ReferenceReport *report);
#ifdef __cplusplus
}
#endif
#endif
