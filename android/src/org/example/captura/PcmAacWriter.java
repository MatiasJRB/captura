package org.example.captura;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import java.io.FileDescriptor;
import java.io.IOException;
import java.nio.ByteBuffer;

/** One M4A chunk from the same PCM stream used by the command recognizer. */
final class PcmAacWriter implements AutoCloseable {
    private final MediaCodec codec;
    private final MediaMuxer muxer;
    private final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
    private int track = -1;
    private long samples;
    private boolean muxing, closed;

    PcmAacWriter(FileDescriptor fd) throws IOException {
        MediaCodec encoder = null;
        MediaMuxer container = null;
        try {
            container = new MediaMuxer(fd, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
            MediaFormat format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, 16000, 1);
            format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
            format.setInteger(MediaFormat.KEY_BIT_RATE, 24000);
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4096);
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            encoder.start();
        } catch (Exception error) {
            if (encoder != null) encoder.release();
            if (container != null) container.release();
            throw new IOException("No se pudo iniciar AAC", error);
        }
        codec = encoder; muxer = container;
    }

    void write(byte[] pcm, int length) throws IOException {
        int offset = 0;
        long deadline = android.os.SystemClock.elapsedRealtime() + 1000;
        while (offset < length) {
            drain(false);
            int index = codec.dequeueInputBuffer(10_000);
            if (index < 0) {
                if (android.os.SystemClock.elapsedRealtime() > deadline)
                    throw new IOException("AAC no acepta audio");
                continue;
            }
            ByteBuffer buffer = codec.getInputBuffer(index);
            if (buffer == null) throw new IOException("AAC sin buffer");
            buffer.clear();
            int count = Math.min(buffer.remaining(), length - offset) & ~1;
            if (count == 0) throw new IOException("AAC buffer demasiado pequeño");
            buffer.put(pcm, offset, count);
            codec.queueInputBuffer(index, 0, count, samples * 1_000_000L / 16000, 0);
            samples += count / 2; offset += count;
        }
        drain(false);
    }

    private boolean drain(boolean wait) throws IOException {
        while (true) {
            int index = codec.dequeueOutputBuffer(info, wait ? 10_000 : 0);
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                if (muxing) throw new IOException("AAC cambió de formato");
                track = muxer.addTrack(codec.getOutputFormat()); muxer.start(); muxing = true;
            } else if (index >= 0) {
                ByteBuffer data = codec.getOutputBuffer(index);
                try {
                    if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 && info.size > 0) {
                        if (!muxing || data == null) throw new IOException("AAC sin formato");
                        data.position(info.offset); data.limit(info.offset + info.size);
                        muxer.writeSampleData(track, data, info);
                    }
                } finally { codec.releaseOutputBuffer(index, false); }
                if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return true;
            } else { return false; }
        }
    }

    @Override public void close() throws IOException {
        if (closed) return;
        closed = true;
        try {
            long deadline = android.os.SystemClock.elapsedRealtime() + 1500;
            int index;
            while ((index = codec.dequeueInputBuffer(10_000)) < 0) {
                drain(false);
                if (android.os.SystemClock.elapsedRealtime() > deadline)
                    throw new IOException("AAC no pudo cerrar el archivo");
            }
            codec.queueInputBuffer(index, 0, 0, samples * 1_000_000L / 16000,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
            while (!drain(true)) {
                if (android.os.SystemClock.elapsedRealtime() > deadline)
                    throw new IOException("AAC no confirmó fin de archivo");
            }
            if (!muxing || samples == 0) throw new IOException("Archivo sin audio");
            muxer.stop();
        } finally {
            try { codec.stop(); } finally {
                codec.release(); muxer.release();
            }
        }
    }
}
