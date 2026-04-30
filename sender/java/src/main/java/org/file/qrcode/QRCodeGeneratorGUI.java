package org.file.qrcode;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.WriterException;
import com.google.zxing.client.j2se.MatrixToImageWriter;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;

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
    private static final int QR_SIZE = 350;
    private static final int DISPLAY_INTERVAL = 2000;

    private ObjectMapper objectMapper = new ObjectMapper();
    private List<DataChunk> allChunks;
    private List<DataChunk> chunks;
    /** 预计算的二维码图标缓存（当前分片列表对应的图标） */
    private List<ImageIcon> precomputedIcons;
    /** 全部二维码图标缓存（筛选恢复时使用） */
    private List<ImageIcon> allPrecomputedIcons;
    /** 实际生成的二维码图片尺寸（像素） */
    private int actualQrWidth;
    private int actualQrHeight;
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
    private JTextField filterInput;
    private JButton btnApplyFilter;
    private JButton btnResetFilter;
    private JLabel filterTipLabel;

    public QRCodeGeneratorGUI(List<DataChunk> chunks) {
        this.allChunks = new ArrayList<>(chunks);
        this.chunks = chunks;
        precomputeAllQRCodes();
        initUI();
        displayChunk(0);
        setupTimer();
    }

    /** 预计算所有分片的二维码图标，避免播放时在EDT上做耗时运算 */
    private void precomputeAllQRCodes() {
        allPrecomputedIcons = new ArrayList<>(chunks.size());
        for (int i = 0; i < chunks.size(); i++) {
            try {
                String json = objectMapper.writeValueAsString(chunks.get(i));
                BufferedImage qrImage = generateQRCode(json);
                if (i == 0) {
                    actualQrWidth = qrImage.getWidth();
                    actualQrHeight = qrImage.getHeight();
                }
                allPrecomputedIcons.add(new ImageIcon(qrImage));
            } catch (Exception e) {
                e.printStackTrace();
                allPrecomputedIcons.add(null);
            }
        }
        precomputedIcons = allPrecomputedIcons;
    }

    private void initUI() {
        setTitle("二维码传输 - 发送器 - " + chunks.get(0).fileName);
        setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);
        // 窗口尺寸根据实际二维码图片大小动态计算
        int winWidth = actualQrWidth + 410;
        int winHeight = Math.max(actualQrHeight, 350) + 155;
        setSize(winWidth, winHeight);
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

        // 片段筛选控制
        JPanel filterPanel = new JPanel(new BorderLayout(5, 5));
        filterPanel.setBorder(BorderFactory.createEmptyBorder(5, 5, 5, 5));
        filterPanel.setMaximumSize(new Dimension(Integer.MAX_VALUE, 120));
        filterPanel.setAlignmentX(Component.CENTER_ALIGNMENT);

        JLabel filterLabel = new JLabel("片段筛选（JSON数组）", JLabel.CENTER);
        filterLabel.setFont(new Font("微软雅黑", Font.PLAIN, 11));

        JPanel filterInputPanel = new JPanel(new BorderLayout(5, 5));
        filterInput = new JTextField("[1,2,3]");
        filterInput.setFont(new Font("微软雅黑", Font.PLAIN, 11));
        filterInput.setHorizontalAlignment(JTextField.CENTER);

        JPanel filterButtonPanel = new JPanel(new GridLayout(1, 2, 5, 0));
        btnApplyFilter = new JButton("应用");
        btnApplyFilter.setFont(new Font("微软雅黑", Font.PLAIN, 11));
        btnApplyFilter.setBackground(new Color(33, 150, 243));
        btnApplyFilter.setForeground(Color.BLACK);
        btnApplyFilter.addActionListener(e -> applyFilter());

        btnResetFilter = new JButton("恢复全部");
        btnResetFilter.setFont(new Font("微软雅黑", Font.PLAIN, 11));
        btnResetFilter.setBackground(new Color(158, 158, 158));
        btnResetFilter.setForeground(Color.BLACK);
        btnResetFilter.addActionListener(e -> resetFilter());

        filterButtonPanel.add(btnApplyFilter);
        filterButtonPanel.add(btnResetFilter);

        filterInputPanel.add(filterInput, BorderLayout.CENTER);
        filterInputPanel.add(filterButtonPanel, BorderLayout.SOUTH);

        filterTipLabel = new JLabel(" ", JLabel.CENTER);
        filterTipLabel.setFont(new Font("微软雅黑", Font.PLAIN, 10));
        filterTipLabel.setPreferredSize(new Dimension(0, 20));

        filterPanel.add(filterLabel, BorderLayout.NORTH);
        filterPanel.add(filterInputPanel, BorderLayout.CENTER);
        filterPanel.add(filterTipLabel, BorderLayout.SOUTH);

        controlPanel.add(btnPause);
        controlPanel.add(Box.createVerticalStrut(5));
        controlPanel.add(btnPrevious);
        controlPanel.add(Box.createVerticalStrut(5));
        controlPanel.add(btnNext);
        controlPanel.add(Box.createVerticalStrut(5));
        controlPanel.add(speedPanel);
        controlPanel.add(Box.createVerticalStrut(5));
        controlPanel.add(btnReset);
        controlPanel.add(Box.createVerticalStrut(5));
        controlPanel.add(filterPanel);

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
    }

    private void setupTimer() {
        // 使用单次定时器 + 自重启模式，严格保证两次切换之间至少 interval 毫秒
        timer = new javax.swing.Timer(DISPLAY_INTERVAL, new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                if (!isPaused) {
                    currentIndex = (currentIndex + 1) % chunks.size();
                    displayChunk(currentIndex);
                }
                timer.restart();
            }
        });
        timer.setRepeats(false);
        timer.start();
    }

    private void displayChunk(int index) {
        try {
            currentIndex = index;
            qrImageLabel.setIcon(precomputedIcons.get(index));

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

        // 第一次编码获取精确模块数（传入0获得原始尺寸）
        BitMatrix probeMatrix = qrCodeWriter.encode(
                content, BarcodeFormat.QR_CODE, 0, 0, hints
        );
        int modules = probeMatrix.getWidth();

        // 计算模块的整数倍像素值（向上取整），消除额外白边
        int moduleSize = Math.max(1, (QR_SIZE + modules - 1) / modules);
        int exactSize = moduleSize * modules;

        // 以精确尺寸重新编码
        BitMatrix bitMatrix = qrCodeWriter.encode(
                content, BarcodeFormat.QR_CODE, exactSize, exactSize, hints
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
        if (timer != null) timer.restart();
    }

    private void nextChunk() {
        currentIndex = (currentIndex + 1) % chunks.size();
        displayChunk(currentIndex);
        if (timer != null) timer.restart();
    }

    private void jumpToSelected() {
        int selectedIndex = chunkList.getSelectedIndex();
        if (selectedIndex >= 0) {
            displayChunk(selectedIndex);
            if (timer != null) timer.restart();
        }
    }

    private void resetToFirst() {
        displayChunk(0);
        if (timer != null) timer.restart();
    }

    private void applyInterval() {
        try {
            String input = intervalInput.getText().trim();
            int interval = Integer.parseInt(input);

            // 限制间隔范围在 50 毫秒到 30000 毫秒之间
            if (interval < 50 || interval > 30000) {
                showIntervalTip("间隔必须在 50 到 30000 毫秒之间", Color.RED);
                return;
            }

            // 应用新的间隔，并立即重置当前周期使其立刻生效
            if (timer != null) {
                timer.setDelay(interval);
                timer.setInitialDelay(interval);
                timer.restart();
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

    private void applyFilter() {
        try {
            String input = filterInput.getText().trim();

            // 解析JSON数组
            int[] indices = objectMapper.readValue(input, int[].class);

            if (indices.length == 0) {
                showFilterTip("数组不能为空", Color.RED);
                return;
            }

            // 创建筛选后的chunks列表
            List<DataChunk> filteredChunks = new ArrayList<>();
            for (int index : indices) {
                // 用户输入从1开始，需要验证范围是1到allChunks.size()
                if (index < 1 || index > allChunks.size()) {
                    showFilterTip("索引 " + index + " 超出范围 (1-" + allChunks.size() + ")", Color.RED);
                    return;
                }
                // 转换为从0开始的内部索引
                filteredChunks.add(allChunks.get(index - 1));
            }

            // 更新chunks列表和图标缓存
            this.chunks = filteredChunks;
            List<ImageIcon> filteredIcons = new ArrayList<>();
            for (int index : indices) {
                filteredIcons.add(allPrecomputedIcons.get(index - 1));
            }
            this.precomputedIcons = filteredIcons;

            // 更新片段列表显示
            updateChunkList();

            // 重置到第一个片段
            currentIndex = 0;
            displayChunk(0);
            if (timer != null) timer.restart();

            showFilterTip("已筛选 " + filteredChunks.size() + " 个片段", new Color(33, 150, 243));

        } catch (Exception ex) {
            showFilterTip("JSON格式错误，请输入如 [1,2,3]", Color.RED);
        }
    }

    private void resetFilter() {
        // 恢复所有片段和图标
        this.chunks = allChunks;
        this.precomputedIcons = allPrecomputedIcons;

        // 更新片段列表显示（恢复原始格式）
        listModel.clear();
        for (int i = 0; i < chunks.size(); i++) {
            listModel.addElement(String.format("片段 %d/%d", i + 1, chunks.size()));
        }

        // 重置到第一个片段
        currentIndex = 0;
        displayChunk(0);
        if (timer != null) timer.restart();

        showFilterTip("已恢复全部 " + allChunks.size() + " 个片段", new Color(76, 175, 80));
    }

    private void updateChunkList() {
        listModel.clear();
        for (int i = 0; i < chunks.size(); i++) {
            DataChunk chunk = chunks.get(i);
            // chunk.chunkIndex是从0开始的，显示时+1
            listModel.addElement(String.format("片段 %d/%d (原始: %d)",
                    i + 1, chunks.size(), chunk.chunkIndex + 1));
        }
    }

    private void showFilterTip(String message, Color color) {
        filterTipLabel.setText(message);
        filterTipLabel.setForeground(color);

        // 2秒后清除提示
        javax.swing.Timer tipTimer = new javax.swing.Timer(2000, e -> {
            filterTipLabel.setText(" ");
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
