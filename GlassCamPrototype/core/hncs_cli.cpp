#include "hncs_c.h"
#include <cstdlib>
#include <string>
#include <iostream>
#include <vector>
// Native golden harness: hncs_cli CCT [legacy|lstar] [standard|reproduction] < packed-f64-rgb > packed-u16-rgb.
// Host endian binary; test driver and executable must share a host.
int main(int argc,char**argv) {
    if(argc<2||argc>4){std::cerr<<"usage: hncs_cli CCT [legacy|lstar] [standard|reproduction] < native-f64.rgb > codes-u16.rgb\n";return 2;}
    char *end=nullptr;double kelvin=std::strtod(argv[1],&end);
    if(!end||end==argv[1]||*end){std::cerr<<"Invalid CCT\n";return 2;}
    std::string space=argc>2?argv[2]:"legacy",intent=argc>3?argv[3]:"standard";
    if((space!="legacy"&&space!="lstar")||(intent!="standard"&&intent!="reproduction"))return 2;
    hncs_context *c=hncs_create_mode(0,kelvin,space=="lstar",intent=="reproduction");if(!c)return 2;
    constexpr size_t batch=4096;
    std::vector<double> input(batch*3);std::vector<uint16_t> output(batch*3);
    while(std::cin) {
        std::cin.read(reinterpret_cast<char*>(input.data()),std::streamsize(input.size()*sizeof(double)));
        auto bytes=std::cin.gcount();if(bytes==0)break;
        if(bytes%(3*sizeof(double))){hncs_destroy(c);return 3;}
        size_t n=size_t(bytes)/(3*sizeof(double));
        if(hncs_render_native(c,input.data(),output.data(),n)){hncs_destroy(c);return 4;}
        std::cout.write(reinterpret_cast<char*>(output.data()),std::streamsize(n*3*sizeof(uint16_t)));
    }
    hncs_destroy(c);return std::cout?0:5;
}
