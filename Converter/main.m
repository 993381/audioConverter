#include <AudioToolbox/AudioToolbox.h>

#define kInputFileLocation CFSTR("/Users/crivers/Desktop/Kyoto Bell.mp3")
#define kOutputFileLocation CFSTR("/Users/crivers/Desktop/output.wav")

#pragma mark user data struct
typedef struct MyAudioConverterSettings {
    
    AudioStreamBasicDescription inputFormat;
    AudioStreamBasicDescription outputFormat;
    
    AudioFileID inputFile;
    AudioFileID outputFile;
    
    UInt64 inputFilePacketIndex;
    UInt64 inputFilePacketCount;
    UInt32 inputFilePacketMaxSize;
    AudioStreamPacketDescription *inputFilePacketDescriptions;
    
    void *sourceBuffer;
    
} MyAudioConverterSettings;


#pragma mark converter callback function
OSStatus MyAudioConverterCallback(
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
    OSStatus result = AudioFileReadPackets(audioConverterSettings->inputFile,
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
// 4.2
// 6.7-6.15
void Convert(MyAudioConverterSettings *mySettings) {
    // Create the audio converter object
    AudioConverterRef audioConverter;
    OSStatus err = AudioConverterNew(&mySettings->inputFormat, &mySettings->outputFormat, &audioConverter);
    
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
    UInt32 outputFilePacketPosition = 0;
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
        
        // Write the converted data to the output file
        OSStatus err = AudioFileWritePackets(mySettings->outputFile, FALSE, ioOutputDataPackets, NULL, outputFilePacketPosition / mySettings->outputFormat.mBytesPerPacket, &ioOutputDataPackets, convertedData.mBuffers[0].mData);
        outputFilePacketPosition += (ioOutputDataPackets * mySettings->outputFormat.mBytesPerPacket);
        
        printf("%d\n", (int)err);
    }
    
    AudioConverterDispose(audioConverter);
}

#pragma mark main function
int main(int argc, const char *argv[]) {
    
    // Open input file
    MyAudioConverterSettings audioConverterSettings = {0};
    
    CFURLRef inputFileURL = CFURLCreateWithFileSystemPath(
                                                          kCFAllocatorDefault,
                                                          kInputFileLocation,
                                                          kCFURLPOSIXPathStyle,
                                                          false);
    
    OSStatus err = AudioFileOpenURL(inputFileURL, kAudioFileReadPermission, 0, &audioConverterSettings.inputFile);
    CFRelease(inputFileURL);
    
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
    
    audioConverterSettings.outputFormat.mSampleRate = 44100.0;
    audioConverterSettings.outputFormat.mFormatID = kAudioFormatLinearPCM;
    audioConverterSettings.outputFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    
    audioConverterSettings.outputFormat.mBitsPerChannel = 32;
    audioConverterSettings.outputFormat.mChannelsPerFrame = 1;
    audioConverterSettings.outputFormat.mBytesPerFrame = 4;
    
    audioConverterSettings.outputFormat.mFramesPerPacket = 1;
    audioConverterSettings.outputFormat.mBytesPerPacket = 4;
    
    CFURLRef outputFileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, kOutputFileLocation, kCFURLPOSIXPathStyle, false);
    err = AudioFileCreateWithURL(outputFileURL, kAudioFileWAVEType, &audioConverterSettings.outputFormat, kAudioFileFlags_EraseFile, &audioConverterSettings.outputFile);
    CFRelease(outputFileURL);
    
    fprintf(stdout, "Converting...\n");
    Convert(&audioConverterSettings);
    
cleanup:
    AudioFileClose(audioConverterSettings.inputFile);
    AudioFileClose(audioConverterSettings.outputFile);
    
    return 0;
}
