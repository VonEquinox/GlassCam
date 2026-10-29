"""Build the native C ABI used by the standalone HNCS benchmark."""
import ctypes as c

from native_build import build_product
from .native import ROOT, configure


def library():
    return configure(c.CDLL(str(build_product())))
