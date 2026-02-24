package org.file.qrcode;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.WriterException;
import com.google.zxing.client.j2se.MatrixToImageWriter;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;
import com.fasterxml.jackson.databind.ObjectMapper;

import javax.swing.*;
import java.awt.*;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import java.util.List;
import java.util.zip.CRC32;

/**
 * 二维码生成器 - 支持暂停、选择片段、手动控制
 */
public class QRCodeGeneratorGUI extends JFrame {

    /** 分片大小(Byte) */
    private static final int CHUNK_SIZE = 1024;
    /** 二维码尺寸(像素) */
    private static final int QR_SIZE = 800;
    private static final int DISPLAY_INTERVAL = 2000;

    private ObjectMapper objectMapper = new ObjectMapper();
    private List<DataChunk> chunks;
    private int currentIndex = 0;
    private boolean isPaused = false;
    private javax.swing.Timer timer;

    // UI组件
    private JLabel qrImageLabel;
    private JButton btnPause;
    private JButton btnPrevious;
    private JButton btnNext;
    private JList<String> chunkList;
    private DefaultListModel<String> listModel;
    private JTextField intervalInput;
    private JButton btnApplyInterval;
    private JLabel speedLabel;
    private JLabel intervalTipLabel;

    public QRCodeGeneratorGUI(List<DataChunk> chunks) {
        this.chunks = chunks;
        initUI();
        setupTimer();
    }

    private void initUI() {
        setTitle("二维码传输 - 发送器 - " + chunks.get(0).fileName);
        setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);
        setSize(1200, 850);
        setLocationRelativeTo(null);

        // 主面板
        JPanel mainPanel = new JPanel(new BorderLayout(10, 10));
        mainPanel.setBorder(BorderFactory.createEmptyBorder(10, 10, 10, 10));

        // 左侧：二维码显示区
        JPanel leftPanel = new JPanel(new BorderLayout());
        leftPanel.setBorder(BorderFactory.createTitledBorder("二维码显示"));

        qrImageLabel = new JLabel();
        qrImageLabel.setHorizontalAlignment(JLabel.CENTER);
        qrImageLabel.setVerticalAlignment(JLabel.CENTER);
        leftPanel.add(qrImageLabel, BorderLayout.CENTER);

        // 右侧：控制面板
        JPanel rightPanel = new JPanel(new BorderLayout());
        rightPanel.setPreferredSize(new Dimension(350, 0));

        // 控制按钮区 - 使用BoxLayout以便更灵活的布局
        JPanel controlPanel = new JPanel();
        controlPanel.setLayout(new BoxLayout(controlPanel, BoxLayout.Y_AXIS));
        controlPanel.setBorder(BorderFactory.createTitledBorder("播放控制"));

        btnPause = new JButton("暂停");
        btnPause.setFont(new Font("微软雅黑", Font.PLAIN, 12));
        btnPause.setBackground(new Color(255, 152, 0));
        btnPause.setForeground(Color.BLACK);
        btnPause.setMaximumSize(new Dimension(Integer.MAX_VALUE, 40));
        btnPause.setAlignmentX(Component.CENTER_ALIGNMENT);
        btnPause.addActionListener(e -> togglePause());

        btnPrevious = new JButton("◀ 上一个");
        btnPrevious.setFont(new Font("微软雅黑", Font.PLAIN, 12));
        btnPrevious.setMaximumSize(new Dimension(Integer.MAX_VALUE, 40));
        btnPrevious.setAlignmentX(Component.CENTER_ALIGNMENT);
        btnPrevious.addActionListener(e -> previousChunk());

        btnNext = new JButton("下一个 ▶");
        btnNext.setFont(new Font("微软雅黑", Font.PLAIN, 12));
        btnNext.setMaximumSize(new Dimension(Integer.MAX_VALUE, 40));
        btnNext.setAlignmentX(Component.CENTER_ALIGNMENT);
        btnNext.addActionListener(e -> nextChunk());

        // 速度控制
        JPanel speedPanel = new JPanel(new BorderLayout(5, 5));
        speedPanel.setBorder(BorderFactory.createEmptyBorder(5, 5, 5, 5));
        speedPanel.setMaximumSize(new Dimension(Integer.MAX_VALUE, 100));
        speedPanel.setAlignmentX(Component.CENTER_ALIGNMENT);

        speedLabel = new JLabel("切换间隔: 2000 毫秒", JLabel.CENTER);
        speedLabel.setFont(new Font("微软雅黑", Font.PLAIN, 11));

        JPanel inputPanel = new JPanel(new BorderLayout(5, 0));
        JLabel inputLabel = new JLabel("间隔(毫秒):");
        inputLabel.setFont(new Font("微软雅黑", Font.PLAIN, 11));

        intervalInput = new JTextField(String.valueOf(DISPLAY_INTERVAL));
        intervalInput.setFont(new Font("微软雅黑", Font.PLAIN, 12));
        intervalInput.setHorizontalAlignment(JTextField.CENTER);

        btnApplyInterval = new JButton("应用");
        btnApplyInterval.setFont(new Font("微软雅黑", Font.PLAIN, 11));
        btnApplyInterval.setBackground(new Color(76, 175, 80));
        btnApplyInterval.setForeground(Color.BLACK);
        btnApplyInterval.addActionListener(e -> applyInterval());

        inputPanel.add(inputLabel, BorderLayout.WEST);
        inputPanel.add(intervalInput, BorderLayout.CENTER);
        inputPanel.add(btnApplyInterval, BorderLayout.EAST);

        // 提示信息标签
        intervalTipLabel = new JLabel(" ", JLabel.CENTER);
        intervalTipLabel.setFont(new Font("微软雅黑", Font.PLAIN, 10));
        intervalTipLabel.setPreferredSize(new Dimension(0, 20));

        speedPanel.add(speedLabel, BorderLayout.NORTH);
        speedPanel.add(inputPanel, BorderLayout.CENTER);
        speedPanel.add(intervalTipLabel, BorderLayout.SOUTH);

        JButton btnReset = new JButton("重新开始");
        btnReset.setFont(new Font("微软雅黑", Font.PLAIN, 12));
        btnReset.setMaximumSize(new Dimension(Integer.MAX_VALUE, 40));
        btnReset.setAlignmentX(Component.CENTER_ALIGNMENT);
        btnReset.addActionListener(e -> resetToFirst());

        controlPanel.add(btnPause);
        controlPanel.add(Box.createVerticalStrut(5));
        controlPanel.add(btnPrevious);
        controlPanel.add(Box.createVerticalStrut(5));
        controlPanel.add(btnNext);
        controlPanel.add(Box.createVerticalStrut(5));
        controlPanel.add(speedPanel);
        controlPanel.add(Box.createVerticalStrut(5));
        controlPanel.add(btnReset);

        // 片段列表
        JPanel listPanel = new JPanel(new BorderLayout());
        listPanel.setBorder(BorderFactory.createTitledBorder("片段列表（双击跳转）"));

        listModel = new DefaultListModel<>();
        for (int i = 0; i < chunks.size(); i++) {
            listModel.addElement(String.format("片段 %d/%d", i + 1, chunks.size()));
        }

        chunkList = new JList<>(listModel);
        chunkList.setFont(new Font("Courier", Font.PLAIN, 12));
        chunkList.setSelectionMode(ListSelectionModel.SINGLE_SELECTION);
        chunkList.addMouseListener(new java.awt.event.MouseAdapter() {
            public void mouseClicked(java.awt.event.MouseEvent evt) {
                if (evt.getClickCount() == 2) {
                    jumpToSelected();
                }
            }
        });

        JScrollPane scrollPane = new JScrollPane(chunkList);
        listPanel.add(scrollPane, BorderLayout.CENTER);

        // 统计信息
        JPanel statsPanel = new JPanel(new GridLayout(4, 1));
        statsPanel.setBorder(BorderFactory.createTitledBorder("文件信息"));
        statsPanel.add(new JLabel("文件名: " + chunks.get(0).fileName));
        statsPanel.add(new JLabel("文件ID: " + chunks.get(0).fileId));
        statsPanel.add(new JLabel("总片段数: " + chunks.size()));

        // 计算原始文件大小
        int totalSize = chunks.size() * CHUNK_SIZE;
        String sizeStr = totalSize < 1024 ? totalSize + " B" :
                        totalSize < 1024 * 1024 ? String.format("%.1f KB", totalSize / 1024.0) :
                        String.format("%.1f MB", totalSize / (1024.0 * 1024));
        statsPanel.add(new JLabel("约 " + sizeStr));

        // 组装右侧面板
        // 将控制面板包裹在容器中以限制大小
        JPanel controlWrapper = new JPanel(new BorderLayout());
        controlWrapper.add(controlPanel, BorderLayout.NORTH);

        rightPanel.add(controlWrapper, BorderLayout.NORTH);
        rightPanel.add(listPanel, BorderLayout.CENTER);
        rightPanel.add(statsPanel, BorderLayout.SOUTH);

        // 组装主面板
        mainPanel.add(leftPanel, BorderLayout.CENTER);
        mainPanel.add(rightPanel, BorderLayout.EAST);

        add(mainPanel);

        // 添加组件监听器，确保布局完成后再显示第一个二维码
        qrImageLabel.addComponentListener(new java.awt.event.ComponentAdapter() {
            private boolean firstDisplay = true;
            @Override
            public void componentResized(java.awt.event.ComponentEvent e) {
                if (firstDisplay && qrImageLabel.getWidth() > 0) {
                    firstDisplay = false;
                    displayChunk(0);
                }
            }
        });
    }

    private void setupTimer() {
        timer = new javax.swing.Timer(DISPLAY_INTERVAL, new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                if (!isPaused) {
                    currentIndex = (currentIndex + 1) % chunks.size();
                    displayChunk(currentIndex);
                }
            }
        });
        timer.start();
    }

    private void displayChunk(int index) {
        try {
            currentIndex = index;
            DataChunk chunk = chunks.get(index);
            String json = objectMapper.writeValueAsString(chunk);

            BufferedImage qrImage = generateQRCode(json);

            // 自适应缩放二维码以适应窗口大小
            int labelWidth = qrImageLabel.getWidth();
            int labelHeight = qrImageLabel.getHeight();

            if (labelWidth > 0 && labelHeight > 0) {
                // 保持宽高比，计算缩放后的尺寸
                int qrWidth = qrImage.getWidth();
                int qrHeight = qrImage.getHeight();

                double scaleWidth = (double) labelWidth / qrWidth;
                double scaleHeight = (double) labelHeight / qrHeight;
                double scale = Math.min(scaleWidth, scaleHeight) * 0.95; // 留 5% 边距

                int scaledWidth = (int) (qrWidth * scale);
                int scaledHeight = (int) (qrHeight * scale);

                if (scale < 1.0) {
                    // 需要缩小
                    Image scaledImage = qrImage.getScaledInstance(scaledWidth, scaledHeight, Image.SCALE_SMOOTH);
                    qrImageLabel.setIcon(new ImageIcon(scaledImage));
                } else {
                    // 不需要缩放
                    qrImageLabel.setIcon(new ImageIcon(qrImage));
                }
            } else {
                // 首次显示时标签尺寸可能还未确定
                qrImageLabel.setIcon(new ImageIcon(qrImage));
            }

            // 更新列表选中状态
            chunkList.setSelectedIndex(index);
            chunkList.ensureIndexIsVisible(index);

        } catch (Exception ex) {
            ex.printStackTrace();
        }
    }

    private BufferedImage generateQRCode(String content) throws WriterException {
        Map<EncodeHintType, Object> hints = new HashMap<>();
        hints.put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.L);
        hints.put(EncodeHintType.MARGIN, 2);
        hints.put(EncodeHintType.CHARACTER_SET, "UTF-8");

        QRCodeWriter qrCodeWriter = new QRCodeWriter();
        BitMatrix bitMatrix = qrCodeWriter.encode(
            content, BarcodeFormat.QR_CODE, QR_SIZE, QR_SIZE, hints
        );

        return MatrixToImageWriter.toBufferedImage(bitMatrix);
    }

    private void togglePause() {
        isPaused = !isPaused;
        if (isPaused) {
            btnPause.setText("继续");
            btnPause.setBackground(new Color(76, 175, 80));
        } else {
            btnPause.setText("暂停");
            btnPause.setBackground(new Color(255, 152, 0));
        }
    }

    private void previousChunk() {
        currentIndex = (currentIndex - 1 + chunks.size()) % chunks.size();
        displayChunk(currentIndex);
    }

    private void nextChunk() {
        currentIndex = (currentIndex + 1) % chunks.size();
        displayChunk(currentIndex);
    }

    private void jumpToSelected() {
        int selectedIndex = chunkList.getSelectedIndex();
        if (selectedIndex >= 0) {
            displayChunk(selectedIndex);
        }
    }

    private void resetToFirst() {
        displayChunk(0);
    }

    private void applyInterval() {
        try {
            String input = intervalInput.getText().trim();
            int interval = Integer.parseInt(input);

            // 限制间隔范围在 100 毫秒到 30000 毫秒之间
            if (interval < 100 || interval > 30000) {
                showIntervalTip("间隔必须在 100 到 30000 毫秒之间", Color.RED);
                return;
            }

            // 应用新的间隔
            if (timer != null) {
                timer.setDelay(interval);
            }

            // 更新显示标签
            speedLabel.setText("切换间隔: " + interval + " 毫秒");
            showIntervalTip("已设置为 " + interval + " 毫秒", new Color(76, 175, 80));

        } catch (NumberFormatException ex) {
            showIntervalTip("请输入有效的数字", Color.RED);
        }
    }

    private void showIntervalTip(String message, Color color) {
        intervalTipLabel.setText(message);
        intervalTipLabel.setForeground(color);

        // 2秒后清除提示
        javax.swing.Timer tipTimer = new javax.swing.Timer(2000, e -> {
            intervalTipLabel.setText(" ");
        });
        tipTimer.setRepeats(false);
        tipTimer.start();
    }

    /**
     * 计算字节数组的MD5值
     */
    private static String calculateMD5(byte[] data) throws NoSuchAlgorithmException {
        MessageDigest md = MessageDigest.getInstance("MD5");
        byte[] digest = md.digest(data);
        StringBuilder sb = new StringBuilder();
        for (byte b : digest) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }

    /**
     * 读取文件并分片
     */
    public static List<DataChunk> splitFile(File file) throws IOException {
        byte[] fileBytes = Files.readAllBytes(file.toPath());

        // 使用文件内容的MD5作为fileID,取前16位
        String fileId;
        try {
            String md5 = calculateMD5(fileBytes);
            fileId = md5.substring(0, 16);
        } catch (NoSuchAlgorithmException e) {
            // 如果MD5算法不可用,降级使用UUID
            fileId = UUID.randomUUID().toString().substring(0, 8);
            System.err.println("警告: MD5算法不可用,使用UUID作为fileID");
        }

        String fileName = file.getName();

        int totalChunks = (int) Math.ceil((double) fileBytes.length / CHUNK_SIZE);
        List<DataChunk> chunks = new ArrayList<>();

        for (int i = 0; i < totalChunks; i++) {
            int start = i * CHUNK_SIZE;
            int end = Math.min(start + CHUNK_SIZE, fileBytes.length);
            byte[] chunkData = Arrays.copyOfRange(fileBytes, start, end);

            String base64Data = Base64.getEncoder().encodeToString(chunkData);

            CRC32 crc32 = new CRC32();
            crc32.update(chunkData);

            DataChunk chunk = new DataChunk(
                fileId, fileName, totalChunks, i, base64Data, crc32.getValue()
            );
            chunks.add(chunk);
        }

        return chunks;
    }

    public static void main(String[] args) {
        if (args.length == 0) {
            System.out.println("使用方法: java QRCodeGeneratorGUI <文件路径>");
            System.out.println("示例: java QRCodeGeneratorGUI test.pdf");
            return;
        }

        try {
            File file = new File(args[0]);
            if (!file.exists()) {
                System.err.println("文件不存在: " + args[0]);
                return;
            }

            System.out.println("正在读取文件: " + file.getName());
            System.out.println("文件大小: " + file.length() + " 字节");

            List<DataChunk> chunks = splitFile(file);
            System.out.println("已分割为 " + chunks.size() + " 个片段");
            System.out.println("启动GUI界面...");

            SwingUtilities.invokeLater(() -> {
                QRCodeGeneratorGUI gui = new QRCodeGeneratorGUI(chunks);
                gui.setVisible(true);
            });

        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
