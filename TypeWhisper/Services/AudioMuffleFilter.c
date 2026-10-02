#include "AudioMuffleFilter.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct AudioMuffleFilter {
    double b0, b1, b2, a1, a2;
    double z1[2], z2[2];
    UInt32 channels;
    UInt32 rampFrames, processedFrames;
    atomic_bool failed;
};

AudioMuffleFilter *AudioMuffleFilterCreate(double sampleRate, UInt32 channelCount) {
    if (!isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 384000 || channelCount == 0 || channelCount > 2) return NULL;
    AudioMuffleFilter *filter = calloc(1, sizeof(*filter));
    if (!filter) return NULL;
    // A 650 Hz Butterworth low-pass keeps bass and removes most speech-range detail.
    const double omega = 2 * M_PI * 650 / sampleRate;
    const double cosine = cos(omega);
    const double alpha = sin(omega) / sqrt(2);
    const double a0 = 1 + alpha;
    filter->b0 = (1 - cosine) / (2 * a0);
    filter->b1 = (1 - cosine) / a0;
    filter->b2 = filter->b0;
    filter->a1 = -2 * cosine / a0;
    filter->a2 = (1 - alpha) / a0;
    filter->channels = channelCount;
    filter->rampFrames = (UInt32)(sampleRate * 0.12);
    atomic_init(&filter->failed, false);
    return filter;
}

void AudioMuffleFilterDestroy(AudioMuffleFilter *filter) { free(filter); }
bool AudioMuffleFilterHasFailed(AudioMuffleFilter *filter) { return atomic_load(&filter->failed); }

OSStatus AudioMuffleFilterIOProc(AudioDeviceID device,
    const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output,
    const AudioTimeStamp *outputTime, void *context) {
    AudioMuffleFilter *filter = context;
    for (UInt32 index = 0; index < output->mNumberBuffers; index++) {
        if (output->mBuffers[index].mData) {
            memset(output->mBuffers[index].mData, 0, output->mBuffers[index].mDataByteSize);
        }
    }
    if (!filter) return noErr;
    const UInt32 bufferCount = output->mNumberBuffers;
    if (bufferCount == 0 || bufferCount > filter->channels || input->mNumberBuffers < bufferCount) {
        atomic_store(&filter->failed, true);
        return noErr;
    }
    // Aggregate input streams place the tap after physical inputs. Only read the tap.
    const UInt32 inputOffset = input->mNumberBuffers - bufferCount;
    UInt32 totalChannels = 0, frames = 0;
    for (UInt32 index = 0; index < bufferCount; index++) {
        const AudioBuffer *source = &input->mBuffers[inputOffset + index];
        const AudioBuffer *target = &output->mBuffers[index];
        if (!source->mData || !target->mData || source->mNumberChannels == 0 ||
            source->mNumberChannels != target->mNumberChannels ||
            source->mDataByteSize != target->mDataByteSize ||
            source->mDataByteSize % (sizeof(float) * source->mNumberChannels) != 0) {
            atomic_store(&filter->failed, true);
            return noErr;
        }
        UInt32 bufferFrames = source->mDataByteSize / (sizeof(float) * source->mNumberChannels);
        if (index > 0 && bufferFrames != frames) {
            atomic_store(&filter->failed, true);
            return noErr;
        }
        frames = bufferFrames;
        totalChannels += source->mNumberChannels;
    }
    if (totalChannels != filter->channels) {
        atomic_store(&filter->failed, true);
        return noErr;
    }
    UInt32 channelOffset = 0;
    for (UInt32 index = 0; index < bufferCount; index++) {
        const AudioBuffer *source = &input->mBuffers[inputOffset + index];
        float *target = output->mBuffers[index].mData;
        const float *samples = source->mData;
        for (UInt32 frame = 0; frame < frames; frame++) {
            double mix = fmin(1, ((double)filter->processedFrames + frame) / filter->rampFrames);
            for (UInt32 channel = 0; channel < source->mNumberChannels; channel++) {
                UInt32 stateChannel = channelOffset + channel;
                UInt32 sampleIndex = frame * source->mNumberChannels + channel;
                double dry = samples[sampleIndex];
                if (!isfinite(dry)) dry = 0;
                double wet = filter->b0 * dry + filter->z1[stateChannel];
                filter->z1[stateChannel] = filter->b1 * dry - filter->a1 * wet + filter->z2[stateChannel];
                filter->z2[stateChannel] = filter->b2 * dry - filter->a2 * wet;
                target[sampleIndex] = (float)(dry + mix * (wet - dry));
            }
        }
        channelOffset += source->mNumberChannels;
    }
    filter->processedFrames = (UInt32)fmin(filter->rampFrames, (double)filter->processedFrames + frames);
    return noErr;
}
