#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

// Storage belongs to one IOProc. Create before start and destroy after the IOProc stops.
typedef struct AudioMuffleFilter AudioMuffleFilter;
AudioMuffleFilter * _Nullable AudioMuffleFilterCreate(double sampleRate, UInt32 channelCount);
void AudioMuffleFilterDestroy(AudioMuffleFilter * _Nonnull filter);
bool AudioMuffleFilterHasFailed(AudioMuffleFilter * _Nonnull filter);
// Processes Float32 buffers without allocation, locks, logging, or runtime calls.
OSStatus AudioMuffleFilterIOProc(AudioDeviceID device,
    const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input,
    const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output,
    const AudioTimeStamp * _Nonnull outputTime,
    void * _Nullable context);
