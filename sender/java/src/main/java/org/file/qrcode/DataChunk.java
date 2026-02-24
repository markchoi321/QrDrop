package org.file.qrcode;

/**
 * 数据片段类
 */
public class DataChunk {
    public String fileId;
    public String fileName;
    public int totalChunks;
    public int chunkIndex;
    public String data;
    public long crc32;

    public DataChunk() {}

    public DataChunk(String fileId, String fileName, int totalChunks,
                    int chunkIndex, String data, long crc32) {
        this.fileId = fileId;
        this.fileName = fileName;
        this.totalChunks = totalChunks;
        this.chunkIndex = chunkIndex;
        this.data = data;
        this.crc32 = crc32;
    }
}