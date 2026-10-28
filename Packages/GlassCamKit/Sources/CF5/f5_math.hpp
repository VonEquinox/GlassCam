#pragma once
#include <array>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

// FP64 executable specification. The mobile implementation uses Metal; this
// reference deliberately favors independently testable operators over memory.
namespace f5 {
constexpr double epsilon_f = 1e-8;
enum class EventKind : uint32_t { interval, upper, lower, bad, repaired, outside, unsupported };
struct Event {
    double x = 0, y = 0, lower = 0, upper = 0, exposure = 1, eta = 1;
    double kappa = 0.001, read_sigma = 0.002, uniform_probability = 1.0 / 16384;
    uint32_t color = 0, phase = 0, frame = 0;
    EventKind kind = EventKind::interval;
    bool valid() const { return kind == EventKind::interval || kind == EventKind::upper || kind == EventKind::lower; }
};
struct Likelihood { double nll = 0, score = 0, curvature = 0, responsibility = 1, probability = 0; };
Likelihood poisson_gaussian(const Event &, double mean, double pi0 = 0);
Likelihood gaussian_event(const Event &, double mean, double pi0 = 0);
double log_normal_cdf(double z);
double cubic(double t);
double cubic_derivative(double t);
int mirror(int i, int length);
struct Stencil {
    std::array<size_t, 16> index{};
    std::array<double, 16> weight{}, dx{}, dy{};
    double evaluate(const std::vector<double> &) const;
    std::array<double, 2> derivative(const std::vector<double> &) const;
    void transpose(double value, std::vector<double> &) const;
};
Stencil stencil(int width, int height, int scale, double x, double y, int color);
struct Motion {
    int columns = 0, rows = 0, spacing = 32;
    std::vector<double> nodes; // interleaved displacement, in input pixels
    std::vector<double> edge_weights;
    struct Weights { std::array<size_t, 4> index; std::array<double, 4> weight; };
    Motion() = default;
    Motion(int width, int height, int spacing = 32);
    Weights weights(double x, double y) const;
    std::array<double, 2> displacement(double x, double y) const;
};
struct Geometry { int width, height, scale, reference; std::array<Motion, 5> motion; };
struct Prediction { Stencil basis; double mean, fx, fy, gain; bool valid; };
Prediction predict(const Geometry &, const Event &, const std::vector<double> &);
std::vector<double> apply_a(const Geometry &, const std::vector<Event> &, const std::vector<double> &);
std::vector<double> apply_at(const Geometry &, const std::vector<Event> &, const std::vector<double> &);
std::vector<double> sample_rgb(const Geometry &, const std::vector<double> &, int output_scale);
struct PCGResult { std::vector<double> x; int iterations = 0; double relative_residual = 0; bool positive = true; };
using Operator = std::function<void(const std::vector<double> &, std::vector<double> &)>;
PCGResult pcg(const Operator &, const std::vector<double> &rhs, const std::vector<double> &diagonal,
              int max_steps, double tolerance);
struct Prolongation {
    int width, height, channels, step, cw, ch;
    Prolongation(int w, int h, int c, int step = 8);
    std::vector<double> apply(const std::vector<double> &) const;
    std::vector<double> transpose(const std::vector<double> &) const;
};
struct Policy {
    int block_size = 256, max_cycles = 50, pcg_steps = 30, geometry_rounds = 3;
    double lambda_y = 1e-4, lambda_c = 4e-4, lambda_motion = 1e-5, pi0 = 0.001;
    double objective_tolerance = 1e-7, gradient_tolerance = 1e-4, max_seconds = 0;
    double gaussian_minimum_electrons = 0; // zero means exact PG everywhere
    bool reverse_blocks = false;
};
struct Trace {
    int scale = 1, epoch = 0, cycles = 0;
    std::vector<double> objective;
    std::vector<double> barrier_tau;
    double standardized_gradient = 0;
    double standardized_motion_gradient = 0;
    std::string stop = "BUDGET_STOP";
};
struct State {
    Geometry geometry;
    std::vector<double> coefficients, noise_scale;
    // Optional frozen RGB direction at each output-grid prior row. Empty
    // retains the original fixed opponent-color prior.
    std::vector<std::array<double,3>> color_axis;
    std::vector<double> color_confidence;
    std::vector<double> luminance_prior_scale;
    std::vector<uint8_t> eligible;
};
struct Evaluation {
    double value = 0;
    std::vector<double> gradient, diagonal;
    Operator q;
    bool feasible = true;
};
struct ImageStep {
    std::vector<double> direction;
    double unguarded_fraction = 1, feasible_fraction = 1;
    int guard_rounds = 0;
};
Evaluation evaluate(const State &, const std::vector<Event> &, const Policy &, double tau, bool derivatives = true);
// Positive local damping changes the search direction, never the objective or
// the signed-coefficient domain. All accepted updates still use true Armijo.
ImageStep image_step(const State &, const std::vector<Event> &, const Evaluation &,
                     const std::vector<size_t> &variables, double damping, int pcg_steps);
// Conservative feasibility safeguard; descent and true-objective acceptance
// must still be checked by the caller. Signed coefficients are retained.
std::vector<double> limit_physical_direction(const State &,const std::vector<Event> &,const std::vector<double> &);
double motion_penalty(const Geometry &, double lambda, size_t event_count);
bool refine_motion(State &, const std::vector<Event> &, const Policy &, double tau,
                   double *standardized_gradient = nullptr, bool update = true);
Trace solve(State &, const std::vector<Event> &, const Policy &, int epoch = 0,
            const std::function<bool()> &cancelled = {});
State initialize(int width, int height, int scale, int reference, const std::vector<Event> &);
void freeze_noise_scale(State &, const std::vector<Event> &);
State lift(const State &native, int scale);

struct Guide {
    int width = 0, height = 0;
    double pixel_size = 1;
    std::vector<double> values, validity, variance;
};
Guide make_guide(int width, int height, int frame, const std::vector<Event> &, int maximum_edge = 512);
struct Alignment {
    std::array<double, 6> affine{1, 0, 0, 0, 1, 0}; // input -> reference
    std::vector<std::array<double, 2>> hypotheses;
    double ambiguity = 0, cycle_error = 0;
};
Alignment align_guides(const Guide &input, const Guide &reference);
struct LocalTranslation {
    std::array<double,2> shift{};
    double cycle_error=0,maximum_std=0,residual=0,normalized_correlation=0;
    size_t samples=0;
    bool reliable=false;
};
LocalTranslation align_local_translation(const Guide &input,const Guide &reference,
                                         double maximum_shift=24,double maximum_std=0.25);
void initialize_motion(State &, const std::array<Guide, 5> &, std::array<Alignment, 5> &);
int choose_reference(const std::array<Guide, 5> &, const std::array<double, 5> &timestamps, double minimum_sharpness);
struct Quality {
    enum Support { full_sr, native_fusion, reference_only, highlight_missing, invalid } support = native_fusion;
    int x = 0, y = 0, width = 0, height = 0;
    std::array<double, 5> valid{}, upper{}, lower{};
    double residual = 0, minimum_information = 0, condition = 0;
    bool short_only = false, ambiguous = false, occluded = false, flicker = false;
};
struct QualityPolicy { double min_information = 1, max_condition = 1000, residual_sigma = 3, max_cycle = 0.5, max_jacobian_deviation = 0; };
std::vector<Quality> diagnose(const State &, const std::vector<Event> &, const std::array<Alignment, 5> &, const QualityPolicy &);
std::vector<double> deliver(const State &high, const State &native, const State &reference,
                            const std::vector<Quality> &, int output_scale = 2);
} // namespace f5
