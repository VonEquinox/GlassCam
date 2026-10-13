#!/usr/bin/env python3
"""Compile and execute the spatial smoke with AddressSanitizer and UBSan."""
import argparse, json, os, pathlib, subprocess, tempfile
from hncs_spatial_evidence import snapshot, environment


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--disable-leak-detection',action='store_true',help='Required in ptrace-based environments where LeakSanitizer cannot operate');ap.add_argument('--output',type=pathlib.Path);args=ap.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];before=snapshot(root)
    with tempfile.TemporaryDirectory(prefix='hncs-spatial-sanitize-') as tmp:
        binary=pathlib.Path(tmp)/'smoke'
        command=[os.environ.get('CXX','c++'),'-std=c++17','-O1','-g','-fno-omit-frame-pointer','-fsanitize=address,undefined','-fno-fast-math','-ffp-contract=off','-Wall','-Wextra','-Wpedantic','-Werror',str(root/'core/hncs_spatial.cpp'),str(root/'core/hncs_numpy_rng.cpp'),str(root/'tests/hncs_spatial_smoke.cpp'),'-o',str(binary)]
        subprocess.run(command,check=True)
        env=os.environ.copy();env['ASAN_OPTIONS']='detect_leaks='+('0' if args.disable_leak_detection else '1')
        result=subprocess.run([str(binary)],env=env,check=True,text=True,capture_output=True)
    assert snapshot(root)==before,'Test sources changed during run'
    report=environment();report.update({'passed':True,'sanitizers':['address','undefined'],'leak_detection':not args.disable_leak_detection,'leak_detection_note':'Disabled for this run because LeakSanitizer cannot run under the execution environment ptrace.' if args.disable_leak_detection else 'Enabled','stdout':result.stdout.strip(),'stderr':result.stderr.strip(),'source_sha256':before})
    if args.output:args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
