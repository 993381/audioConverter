#include <AudioToolbox/AudioToolbox.h>

#define kInputFileLocation CFSTR("/Users/crivers/Desktop/scs.mp3")
#define kOutputFileLocation CFSTR("/Users/crivers/Desktop/output.wav")

#pragma mark user data struct
typedef struct MyAudioConverterSettings {
    
    AudioStreamBasicDescription inputFormat;
    AudioStreamBasicDescription outputFormat;
    
    AudioFileID inputFile;
    
    UInt64 inputFilePacketIndex;
    UInt64 inputFilePacketCount;
    UInt32 inputFilePacketMaxSize;
    AudioStreamPacketDescription *inputFilePacketDescriptions;
    
    void *sourceBuffer;
    void *destination;
    
} MyAudioConverterSettings;

#pragma mark converter callback function
static OSStatus MyAudioConverterCallback(
                                  AudioConverterRef inAudioCOnverter,
                                  UInt32 *ioDataPacketCount,
                                  AudioBufferList *ioData,
                                  AudioStreamPacketDescription **outDataPacketDescription,
                                  void *inUserData)
{
    MyAudioConverterSettings *audioConverterSettings = (MyAudioConverterSettings*)inUserData;
    
    // Clear the buffer
    ioData->mBuffers[0].mData = NULL;
    ioData->mBuffers[0].mDataByteSize = 0;
    
    // If there are not enough packets to satisfy request, then read what's left
    if (audioConverterSettings->inputFilePacketIndex + *ioDataPacketCount > audioConverterSettings->inputFilePacketCount) {
        *ioDataPacketCount = (UInt32)(audioConverterSettings->inputFilePacketCount - audioConverterSettings->inputFilePacketIndex);
    }
    
    if (*ioDataPacketCount == 0) {
        return noErr;
    }
    
    if (audioConverterSettings->sourceBuffer != NULL) {
        free(audioConverterSettings->sourceBuffer);
        audioConverterSettings->sourceBuffer = NULL;
    }
    
    audioConverterSettings->sourceBuffer = (void*)calloc(1, *ioDataPacketCount * audioConverterSettings->inputFilePacketMaxSize);
    
    UInt32 outByteCount = 0;
    // TODO: Use AudioFileReadPacketData instead
    OSStatus result = AudioFileReadPacketData(audioConverterSettings->inputFile,
                                              true,
                                              &outByteCount,
                                              audioConverterSettings->inputFilePacketDescriptions,
                                              audioConverterSettings->inputFilePacketIndex,
                                              ioDataPacketCount,
                                              audioConverterSettings->sourceBuffer);
    
    if (result == eofErr && *ioDataPacketCount) {
        result = kAudioFileEndOfFileError;
    } else if (result != noErr) {
        return result;
    }
    
    // Update source file position and AudioBuffer members with the result of read
    audioConverterSettings->inputFilePacketIndex += *ioDataPacketCount;
    
    ioData->mBuffers[0].mData = audioConverterSettings->sourceBuffer;
    ioData->mBuffers[0].mDataByteSize = outByteCount;
    
    if (outDataPacketDescription) {
        *outDataPacketDescription = audioConverterSettings->inputFilePacketDescriptions;
    }
    
    return result;
}

#pragma mark utility functions
static void Convert(MyAudioConverterSettings *mySettings) {
    // Create the audio converter object
    AudioConverterRef audioConverter;
    AudioConverterNew(&mySettings->inputFormat, &mySettings->outputFormat, &audioConverter);
    
    UInt32 packetsPerBuffer = 0;
    UInt32 outputBufferSize = 32 * 1024; // 32kb
    UInt32 sizePerPacket = mySettings->inputFormat.mBytesPerPacket;
    
    if (sizePerPacket == 0) {
        // Variable bit rate data
        
        // Set sizePerPacket to maximum packet size
        UInt32 size = sizeof(sizePerPacket);
        AudioConverterGetProperty(audioConverter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &sizePerPacket);
        
        // Increase buffer size if maximum package size is larger
        if (sizePerPacket > outputBufferSize) {
            outputBufferSize = sizePerPacket;
        }
        
        packetsPerBuffer = outputBufferSize / sizePerPacket;
        
        // Create an array to hold enough `AudioStreamPacketDescription`s for the entire buffer
        mySettings->inputFilePacketDescriptions = (AudioStreamPacketDescription*)malloc(sizeof(AudioStreamPacketDescription) * packetsPerBuffer);
        
    } else {
        // Constant bit rate
        packetsPerBuffer = outputBufferSize / sizePerPacket;
    }
    
    // Allocate memory for Audio Conversion Buffer
    UInt8 *outputBUffer = (UInt8*)malloc(sizeof(UInt8) * outputBufferSize);
    
    // Start a loop to convert and write data
    UInt32 outputBytePosition = 0;
    while(1) {
        // Prepare an AudioBufferList to receive converted data
        AudioBufferList convertedData;
        convertedData.mNumberBuffers = 1;
        convertedData.mBuffers[0].mNumberChannels = mySettings->inputFormat.mChannelsPerFrame;
        convertedData.mBuffers[0].mDataByteSize = outputBufferSize;
        convertedData.mBuffers[0].mData = outputBUffer;
        
        UInt32 ioOutputDataPackets = packetsPerBuffer;
        OSStatus error = AudioConverterFillComplexBuffer(audioConverter,
                                                         MyAudioConverterCallback,
                                                         mySettings,
                                                         &ioOutputDataPackets,
                                                         &convertedData,
                                                         (mySettings->inputFilePacketDescriptions ? mySettings->inputFilePacketDescriptions : nil));
        
        if (error || !ioOutputDataPackets) {
            // Termination condition
            break;
        }
        
        // Write the converted data to the destination
        char* outPtr = (char*)mySettings->destination;
        memcpy(outPtr + outputBytePosition,
               convertedData.mBuffers[0].mData,
               convertedData.mBuffers[0].mDataByteSize);
        outputBytePosition += convertedData.mBuffers[0].mDataByteSize;
        printf("OPB: %llu\n", outputBytePosition);
    }
    
    AudioConverterDispose(audioConverter);
}

void AudioFileLoad(CFURLRef inFileURL, AudioStreamBasicDescription outputFormat, void** inDest, UInt64* frameCount) {
    // Open input file
    MyAudioConverterSettings audioConverterSettings = {0};
    audioConverterSettings.outputFormat = outputFormat;
    
    CFURLRef inputFileURL = CFURLCreateWithFileSystemPath(
                                                          kCFAllocatorDefault,
                                                          kInputFileLocation,
                                                          kCFURLPOSIXPathStyle,
                                                          false);
    
    AudioFileOpenURL(inputFileURL, kAudioFileReadPermission, 0, &audioConverterSettings.inputFile);
    
    // Get input format
    UInt32 propSize = sizeof(audioConverterSettings.inputFormat);
    AudioFileGetProperty(audioConverterSettings.inputFile,
                         kAudioFilePropertyDataFormat,
                         &propSize,
                         &audioConverterSettings.inputFormat);
    
    // get the total number of packets in the file
    propSize = sizeof(audioConverterSettings.inputFilePacketCount);
    AudioFileGetProperty(audioConverterSettings.inputFile,
                         kAudioFilePropertyAudioDataPacketCount,
                         &propSize,
                         &audioConverterSettings.inputFilePacketCount);
    
    // get size of largest possible packet
    propSize = sizeof(audioConverterSettings.inputFilePacketMaxSize);
    AudioFileGetProperty(audioConverterSettings.inputFile,
                         kAudioFilePropertyMaximumPacketSize,
                         &propSize,
                         &audioConverterSettings.inputFilePacketMaxSize);
    
    AudioFramePacketTranslation audioFramePacketTranslation;
    audioFramePacketTranslation.mPacket = audioConverterSettings.inputFilePacketCount;
    propSize = sizeof(audioFramePacketTranslation);
    AudioFileGetProperty(audioConverterSettings.inputFile, kAudioFilePropertyPacketToFrame, &propSize, &audioFramePacketTranslation);
    
    UInt64 framesToAllocate = ceil(audioFramePacketTranslation.mFrame * (audioConverterSettings.outputFormat.mSampleRate / audioConverterSettings.inputFormat.mSampleRate));
    UInt64 bytesToAllocate = framesToAllocate * audioConverterSettings.outputFormat.mBytesPerPacket;
    
    audioConverterSettings.destination = malloc(bytesToAllocate);
    memset(audioConverterSettings.destination, 0, bytesToAllocate);
    
    Convert(&audioConverterSettings);
    
    AudioFileClose(audioConverterSettings.inputFile);
    
    *inDest = audioConverterSettings.destination;
    *frameCount = framesToAllocate;
}

#pragma mark main function
int main(int argc, const char *argv[]) {
    CFURLRef inputFileURL = CFURLCreateWithFileSystemPath(
                                                          kCFAllocatorDefault,
                                                          kInputFileLocation,
                                                          kCFURLPOSIXPathStyle,
                                                          false);
    

    AudioStreamBasicDescription outputFormat = { 0 };
    outputFormat.mSampleRate = 48000;
    outputFormat.mFormatID = kAudioFormatLinearPCM;
    outputFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    
    outputFormat.mBitsPerChannel = 32;
    outputFormat.mChannelsPerFrame = 1;
    outputFormat.mBytesPerFrame = 4;
    
    outputFormat.mFramesPerPacket = 1;
    outputFormat.mBytesPerPacket = 4;
        
    void* dest;
    UInt64 frames;
    AudioFileLoad(inputFileURL, outputFormat, &dest, &frames);
    CFRelease(inputFileURL);
    
    printf("Convert & loaded %llu frames\n", frames);
    
    return 0;
}
