#!/usr/bin/env python3
"""Controlled mechanism tests for a 4-main + 1-short RAW burst proposal.

Not an iPhone benchmark or an image-reconstruction implementation.
Requires only numpy. Run: python experiments.py --out results.json
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import numpy as np


def alias_row(shift: np.ndarray) -> np.ndarray:
    """Unit-norm row for four aliases in a 2x2 monochrome SR toy model."""
    aliases = np.array([[0., 0.], [1., 0.], [0., 1.], [1., 1.]])
    return np.exp(-2j * np.pi * (aliases @ np.asarray(shift))) / 2.0


def info_summary(f: np.ndarray) -> dict:
    eig = np.linalg.eigvalsh(f)
    if eig[0] <= 0:
        raise ValueError('Expected positive definite information matrix.')
    return {
        'eigenvalues': eig.tolist(),
        'trace': float(eig.sum()),
        'minimum_eigenvalue': float(eig[0]),
        'condition_number': float(eig[-1] / eig[0]),
        'unit_noise_unregularized_trace_covariance': float(np.sum(1 / eig)),
    }


def test_complementarity() -> dict:
    """Known shifts, no blur/CFA/motion uncertainty; shot-normalized weights."""
    shifts = np.array([[0., 0.], [.48, .02], [.02, .48], [.12, .18]])
    a = np.array([alias_row(s) for s in shifts])
    f = a.conj().T @ a
    out = {'main_shifts_pixels': shifts.tolist(), 'short_to_main_exposure': 0.125,
           'four_main': info_summary(f)}
    for name, shift in [('redundant_short', [0., 0.]),
                        ('complementary_short', [.5, .5])]:
        row = alias_row(np.array(shift))
        updated = f + .125 * np.outer(row.conj(), row)
        out[name] = dict(short_shift_pixels=shift, **info_summary(updated))
        assert np.linalg.eigvalsh(updated - f)[0] > -1e-12
    assert np.isclose(out['complementary_short']['trace'], 4.125)
    assert out['complementary_short']['minimum_eigenvalue'] > out['redundant_short']['minimum_eigenvalue']
    return out


def test_random_complementarity(rng: np.random.Generator, n: int = 10000) -> dict:
    """Distribution illustration; uniform shifts are NOT measured hand tremor."""
    ratios = []
    for _ in range(n):
        shifts = rng.uniform(0., 1., size=(5, 2))
        a = np.array([alias_row(s) for s in shifts[:4]])
        f = a.conj().T @ a
        row = alias_row(shifts[4])
        updated = f + .125 * np.outer(row.conj(), row)
        before = np.linalg.eigvalsh(f)[0]
        after = np.linalg.eigvalsh(updated)[0]
        if before > 1e-12:
            ratios.append(float(after / before))
    return {'count': len(ratios), 'distribution': 'independent uniform shifts; synthetic, not measured',
            'min_eigenvalue_ratio_percentiles_10_50_90': np.percentile(ratios, [10, 50, 90]).tolist()}


def test_blur_information() -> dict:
    """One isolated small sinusoidal modulation on a flat bright background.

    For a Poisson, shot-noise-dominated signal and known shift/blur,
    local Fisher information is proportional to T * |H_motion(f)|^2.
    Common nonzero optical/pixel transfer factors cancel in the fraction.
    Blur is uniform translation during exposure, hence H = sinc(f * length).
    This is NOT a complete aliased multicolor inversion model.
    """
    ratio = .125
    rows = []
    for blur in [0., .8, 1.5, 2.]:
        for frequency in [0., .25, .5, .6, .75]:
            long_info = float(np.sinc(frequency * blur) ** 2)
            short_info = float(ratio * np.sinc(frequency * blur * ratio) ** 2)
            fraction = short_info / (4 * long_info + short_info)
            rows.append({'long_blur_length_input_pixels': blur,
                         'frequency_cycles_per_input_pixel': frequency,
                         'short_information_fraction': fraction})
    assert np.isclose(rows[0]['short_information_fraction'], 1/33)
    return {'exposure_ratio': ratio, 'rows': rows}


def test_correlated_registration(rng: np.random.Generator) -> dict:
    """A constant-gradient patch with one shared translation residual.

    r_i = e + n_i, e~N(0,tau^2), n_i~iid N(0,sigma^2).
    All quantities are normalized to the sensor-noise standard deviation.
    """
    n, sigma, tau, draws = 64, 1., 1., 100000
    empirical_means = []
    for _ in range(draws // 1000):
        shared = rng.normal(0., tau, (1000, 1))
        noise = rng.normal(0., sigma, (1000, n))
        empirical_means.append((shared + noise).mean(axis=1))
    observed = float(np.var(np.concatenate(empirical_means), ddof=1))
    true_mean_variance = tau*tau + sigma*sigma / n
    diagonal_mean_variance = (tau*tau + sigma*sigma) / n
    assert abs(observed / true_mean_variance - 1) < .03
    # Numeric verification of low-rank inverse, not just the scalar example.
    g = rng.normal(size=(64, 2))
    d = rng.uniform(.5, 2., size=64)
    sigma_u = np.array([[.01, .002], [.002, .02]])
    c = np.diag(d) + g @ sigma_u @ g.T
    dinv = np.diag(1. / d)
    woodbury = dinv - dinv @ g @ np.linalg.solve(
        np.linalg.inv(sigma_u) + g.T @ dinv @ g, g.T @ dinv)
    direct = np.linalg.inv(c)
    relative_error = float(np.linalg.norm(woodbury-direct) / np.linalg.norm(direct))
    assert relative_error < 1e-12
    return {'pixels_sharing_error': n, 'monte_carlo_draws': draws,
            'sensor_noise_sigma': sigma, 'shared_error_sigma': tau,
            'true_patch_mean_variance': true_mean_variance,
            'diagonal_assumption_patch_mean_variance': diagonal_mean_variance,
            'monte_carlo_patch_mean_variance': observed,
            'variance_underestimation_factor': true_mean_variance / diagonal_mean_variance,
            'woodbury_relative_error': relative_error}


def test_alias_aware_prediction() -> dict:
    """A known sub-Nyquist and super-Nyquist sinusoid; no CFA/noise.

    A 0.75 cycle/input-pixel pattern aliases to -0.25. 0.5 pixel motion
    has a high-frequency phase inconsistent with shifting its LR interpolant.
    Pixel integration is included as a shared sinc transfer factor.
    """
    n = np.arange(128)
    f, shift = .75, .5
    amplitude = float(np.sinc(f))
    physical = amplitude * np.cos(2 * np.pi * f * (n + shift))
    wrong_lr_warp = amplitude * np.cos(2 * np.pi * (-.25) * (n + shift))
    correct_prediction = amplitude * np.cos(2 * np.pi * f * (n + shift))
    wrong_rmse = float(np.sqrt(np.mean((physical-wrong_lr_warp)**2)))
    correct_rmse = float(np.sqrt(np.mean((physical-correct_prediction)**2)))
    return {'frequency': f, 'shift': shift,
            'wrong_lr_bandlimited_warp_rmse': wrong_rmse,
            'correct_forward_prediction_rmse': correct_rmse,
            'note': 'Known ground truth and shift; demonstrates mechanism, not solver performance.'}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=Path('results.json'))
    args = parser.parse_args()
    seed = 20261026
    rng = np.random.default_rng(seed)
    result = {'seed': seed, 'scope': 'controlled mechanism tests, not iPhone results',
              'complementarity': test_complementarity(),
              'random_complementarity': test_random_complementarity(rng),
              'blur_information': test_blur_information(),
              'correlated_registration': test_correlated_registration(rng),
              'alias_aware_prediction': test_alias_aware_prediction()}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
