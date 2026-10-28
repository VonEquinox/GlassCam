// Independent Adobe DNG SDK 1.7.1 oracle. The default mode only characterizes
// color matrices. Pixel/probe modes are explicit and never invoke a look table,
// tone curve, or the SDK's final display renderer.
#include "dng_host.h"
#include "dng_negative.h"
#include "dng_info.h"
#include "dng_file_stream.h"
#include "dng_color_spec.h"
#include "dng_camera_profile.h"
#include "dng_image.h"
#include "dng_pixel_buffer.h"
#include "dng_tag_types.h"
#include "dng_ifd.h"
#include "dng_opcode_list.h"
#include <iostream>
#include <iomanip>
#include <fstream>
#include <vector>
#include <string>
int main(int argc,char **argv) {
    const bool raw=argc==4&&std::string(argv[1])=="--raw-uint16";
    const bool stage3=argc==4&&std::string(argv[1])=="--stage3-float";
    const bool probe2=argc==4&&std::string(argv[1])=="--opcode2-probe";
    const bool probe3=argc==4&&std::string(argv[1])=="--opcode3-probe";
    const bool pixel=raw||stage3||probe2||probe3;
    if(argc!=2&&!pixel)return 2;
    try {
        dng_host host;dng_file_stream stream(argv[pixel?2:1]);dng_info info;
        info.Parse(host,stream);info.PostParse(host);
        AutoPtr<dng_negative>negative(host.Make_dng_negative());
        negative->Parse(host,stream,info);negative->PostParse(host,stream,info);
        if(raw) {
            negative->ReadStage1Image(host,stream,info);
            const auto *source=negative->Stage1Image();if(!source||source->Planes()!=1||source->PixelType()!=ttShort)return 4;
            const auto bounds=source->Bounds();if(bounds.W()>32768||bounds.H()>32768)return 4;
            std::vector<uint16> pixels(size_t(bounds.W())*bounds.H());dng_pixel_buffer buffer;
            buffer.fArea=bounds;buffer.fPlane=0;buffer.fPlanes=1;buffer.fRowStep=bounds.W();buffer.fColStep=1;buffer.fPlaneStep=1;
            buffer.fPixelType=ttShort;buffer.fPixelSize=2;buffer.fData=pixels.data();buffer.fDirty=true;source->Get(buffer);
            std::ofstream output(argv[3],std::ios::binary);output.write(reinterpret_cast<const char*>(pixels.data()),pixels.size()*2);
            if(!output.good())return 5;
            std::cout<<"{\"width\":"<<bounds.W()<<",\"height\":"<<bounds.H()<<",\"stage\":1,\"component\":\"uint16_host_endian\"}\n";return 0;
        }
        if(stage3||probe2||probe3) {
            AutoPtr<dng_image> probe;
            const dng_image *source=nullptr;
            if(stage3) {
                negative->ReadStage1Image(host,stream,info);
                negative->BuildStage2Image(host);negative->BuildStage3Image(host);
                source=negative->Stage3Image();
            } else {
                negative->ReadOpcodeLists(host,stream,info);
                const auto bounds=dng_rect(info.fIFD[info.fMainIndex]->fActiveArea.Size());
                const uint32 planes=probe2?1:3;
                probe.Reset(host.Make_dng_image(bounds,planes,ttFloat));
                std::vector<float> pixels(size_t(bounds.W())*bounds.H()*planes);
                for(size_t i=0;i<pixels.size();++i)pixels[i]=0.02f*float(i%planes+1);
                dng_pixel_buffer buffer;buffer.fArea=bounds;buffer.fPlane=0;buffer.fPlanes=planes;
                buffer.fRowStep=bounds.W()*planes;buffer.fColStep=planes;buffer.fPlaneStep=1;
                buffer.fPixelType=ttFloat;buffer.fPixelSize=4;buffer.fData=pixels.data();buffer.fDirty=true;
                probe->Put(buffer);negative->SetStage3BlackLevel(0);
                host.ApplyOpcodeList(probe2?negative->OpcodeList2():negative->OpcodeList3(),*negative.Get(),probe);
                source=probe.Get();
            }
            if(!source||source->Planes()>3)return 4;
            const auto bounds=source->Bounds();const auto planes=source->Planes();
            std::vector<float> pixels(size_t(bounds.W())*bounds.H()*planes);
            dng_pixel_buffer buffer;buffer.fArea=bounds;buffer.fPlane=0;buffer.fPlanes=planes;
            buffer.fRowStep=bounds.W()*planes;buffer.fColStep=planes;buffer.fPlaneStep=1;
            buffer.fPixelType=ttFloat;buffer.fPixelSize=4;buffer.fData=pixels.data();buffer.fDirty=true;source->Get(buffer);
            std::ofstream output(argv[3],std::ios::binary);output.write(reinterpret_cast<const char*>(pixels.data()),pixels.size()*4);
            if(!output.good())return 5;
            std::cout<<"{\"width\":"<<bounds.W()<<",\"height\":"<<bounds.H()<<",\"channels\":"<<planes
                <<",\"stage\":"<<(probe2?2:3)<<",\"component\":\"float32_host_endian\",\"stage3_gain\":"<<negative->Stage3Gain()
                <<",\"stage3_black_level\":"<<negative->Stage3BlackLevel()<<"}\n";return 0;
        }
        if(negative->ProfileCount()==0)return 3;
        dng_color_spec spec(*negative.Get(),&negative->ProfileByIndex(0));
        auto white=negative->HasCameraNeutral()?spec.NeutralToXY(negative->CameraNeutral()):negative->CameraWhiteXY();
        spec.SetWhiteXY(white);const auto &m=spec.CameraToPCS();
        std::cout<<std::setprecision(17)<<"{\"white_xy\":["<<white.x<<","<<white.y<<"],\"camera_to_xyz_d50\":[";
        for(int row=0;row<3;++row)for(int column=0;column<3;++column){if(row||column)std::cout<<",";std::cout<<m[row][column];}
        std::cout<<"]}\n";return 0;
    } catch(...) {std::cerr<<"DNG SDK rejected the characterization input\n";return 1;}
}
