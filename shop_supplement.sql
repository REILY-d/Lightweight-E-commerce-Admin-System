-- ============================================================
-- shop_supplement.sql  NexMart NOMS 补充脚本
-- 在 shop_setup_v4.sql 基础上补充：
--   1. audit_log 审计日志表
--   2. 三个触发器（INSERT / UPDATE / DELETE）
--   3. 四个存储过程（查询 / 插入 / 删除 / 修改）
-- 执行前提：已成功执行 shop_setup_v4.sql
-- 执行方法：mysql -u root -p shop < shop_supplement.sql
-- ============================================================

USE shop;

-- ══════════════════════════════════════════════════════════
--  一、审计日志表（触发器写入目标）
-- ══════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS audit_log (
    id         BIGINT       PRIMARY KEY AUTO_INCREMENT COMMENT '日志ID',
    user_id    INT          DEFAULT 1                  COMMENT '操作人ID（演示固定为1）',
    action     VARCHAR(20)  NOT NULL                   COMMENT 'INSERT / UPDATE / DELETE',
    table_name VARCHAR(50)  NOT NULL                   COMMENT '被操作的表名',
    record_id  INT          NOT NULL                   COMMENT '被操作记录的主键',
    old_value  TEXT                                    COMMENT '修改前的值（JSON格式）',
    new_value  TEXT                                    COMMENT '修改后的值（JSON格式）',
    op_time    DATETIME     DEFAULT NOW()              COMMENT '操作时间'
) ENGINE=InnoDB COMMENT='操作审计日志';

SELECT '✅ audit_log 表创建完成' AS 进度;


-- ══════════════════════════════════════════════════════════
--  二、触发器
-- ══════════════════════════════════════════════════════════

DELIMITER //

-- ────────────────────────────────────────────────────────
-- 触发器一：INSERT 前触发
-- 作用：下单时自动从 product 表复制当前单价，
--       计算并锁定 total_amount = price × quantity
--       避免商品后续调价影响历史订单金额
-- ────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_orders_before_insert //
CREATE TRIGGER trg_orders_before_insert
    BEFORE INSERT ON orders
    FOR EACH ROW
BEGIN
    DECLARE cur_price DECIMAL(10,2);

    -- 从 product 表获取当前单价
    SELECT price INTO cur_price
    FROM product
    WHERE id = NEW.product_id;

    -- 仅当前端未传入 total_amount 或传入为0时自动计算
    IF NEW.total_amount IS NULL OR NEW.total_amount = 0 THEN
        SET NEW.total_amount = cur_price * NEW.quantity;
    END IF;
END //


-- ────────────────────────────────────────────────────────
-- 触发器二：UPDATE 后触发
-- 作用：订单的 status 或 total_amount 发生变化时，
--       自动向 audit_log 表写入一条审计记录，
--       保存修改前后的值，便于追溯改价和状态变更历史
-- ────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_orders_after_update //
CREATE TRIGGER trg_orders_after_update
    AFTER UPDATE ON orders
    FOR EACH ROW
BEGIN
    -- 只有 status 或 total_amount 实际发生变化时才记录
    IF OLD.status != NEW.status OR OLD.total_amount != NEW.total_amount THEN
        INSERT INTO audit_log (
            user_id, action, table_name, record_id,
            old_value, new_value, op_time
        ) VALUES (
            1,
            'UPDATE',
            'orders',
            NEW.id,
            JSON_OBJECT(
                'status',       OLD.status,
                'total_amount', OLD.total_amount
            ),
            JSON_OBJECT(
                'status',       NEW.status,
                'total_amount', NEW.total_amount
            ),
            NOW()
        );
    END IF;
END //


-- ────────────────────────────────────────────────────────
-- 触发器三：DELETE 前触发
-- 作用：
--   ① 禁止删除"已完成"或"已发货"状态的订单（业务保护）
--   ② 允许删除的订单在删除前先写入审计日志（可追溯）
-- ────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_orders_before_delete //
CREATE TRIGGER trg_orders_before_delete
    BEFORE DELETE ON orders
    FOR EACH ROW
BEGIN
    -- 业务规则：已完成和已发货订单不允许删除
    IF OLD.status IN ('已完成', '已发货') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = '业务规则：禁止删除已完成或已发货的订单';
    END IF;

    -- 允许删除的订单（待支付、已取消），删除前记录审计日志
    INSERT INTO audit_log (
        user_id, action, table_name, record_id,
        old_value, new_value, op_time
    ) VALUES (
        1,
        'DELETE',
        'orders',
        OLD.id,
        JSON_OBJECT(
            'consumer_id',  OLD.consumer_id,
            'product_id',   OLD.product_id,
            'quantity',     OLD.quantity,
            'total_amount', OLD.total_amount,
            'status',       OLD.status,
            'create_time',  DATE_FORMAT(OLD.create_time, '%Y-%m-%d %H:%i:%s')
        ),
        NULL,
        NOW()
    );
END //

DELIMITER ;

SELECT '✅ 三个触发器创建完成' AS 进度;


-- ══════════════════════════════════════════════════════════
--  三、存储过程
-- ══════════════════════════════════════════════════════════

DELIMITER //

-- ────────────────────────────────────────────────────────
-- 存储过程一：多表查询
-- 功能：查询指定消费者姓名的所有订单详情（含商品信息）
-- 入参：消费者姓名（可模糊，如传入"张"可查所有含张的消费者）
-- 出参：结果集（多行）
-- ────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS GetOrdersByConsumerName //
CREATE PROCEDURE GetOrdersByConsumerName(IN p_name VARCHAR(50))
BEGIN
    SELECT
        o.id                                        AS 订单ID,
        c.username                                  AS 消费者姓名,
        c.phone                                     AS 联系电话,
        p.name                                      AS 商品名称,
        p.category                                  AS 商品分类,
        p.price                                     AS 当前单价,
        o.quantity                                  AS 购买数量,
        o.total_amount                              AS 订单金额,
        o.status                                    AS 订单状态,
        DATE_FORMAT(o.create_time, '%Y-%m-%d %H:%i') AS 下单时间
    FROM orders o
    JOIN consumer c ON o.consumer_id = c.id
    JOIN product  p ON o.product_id  = p.id
    WHERE c.username LIKE CONCAT('%', p_name, '%')
    ORDER BY o.create_time DESC;
END //


-- ────────────────────────────────────────────────────────
-- 存储过程二：数据插入
-- 功能：新增商品，含参数合法性校验
-- 入参：商品名、单价、库存、分类、描述
-- 出参：p_result（操作结果说明）、p_new_id（新增商品的ID）
-- ────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS InsertProduct //
CREATE PROCEDURE InsertProduct(
    IN  p_name        VARCHAR(100),
    IN  p_price       DECIMAL(10,2),
    IN  p_stock       INT,
    IN  p_category    VARCHAR(50),
    IN  p_description VARCHAR(500),
    OUT p_result      VARCHAR(200),
    OUT p_new_id      INT
)
BEGIN
    -- 参数校验
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        SET p_result = '失败：商品名称不能为空';
        SET p_new_id = -1;
    ELSEIF p_price IS NULL OR p_price <= 0 THEN
        SET p_result = '失败：单价必须大于 0';
        SET p_new_id = -1;
    ELSEIF p_stock IS NULL OR p_stock < 0 THEN
        SET p_result = '失败：库存不能为负数';
        SET p_new_id = -1;
    ELSE
        INSERT INTO product (name, price, stock, category, description)
        VALUES (
            TRIM(p_name),
            p_price,
            p_stock,
            IFNULL(p_category, '其他'),
            p_description
        );
        SET p_new_id = LAST_INSERT_ID();
        SET p_result = CONCAT('成功：商品已添加，新ID = ', p_new_id);
    END IF;
END //


-- ────────────────────────────────────────────────────────
-- 存储过程三：数据删除
-- 功能：删除指定日期之前的"已取消"订单
-- 入参：p_before_date（截止日期，格式 YYYY-MM-DD）
-- 出参：p_count（实际删除的记录数）
-- ────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS DeleteCancelledOrders //
CREATE PROCEDURE DeleteCancelledOrders(
    IN  p_before_date DATE,
    OUT p_count       INT
)
BEGIN
    -- 先统计将被删除的数量
    SELECT COUNT(*) INTO p_count
    FROM orders
    WHERE status = '已取消'
      AND DATE(create_time) < p_before_date;

    -- 执行删除
    DELETE FROM orders
    WHERE status = '已取消'
      AND DATE(create_time) < p_before_date;
END //


-- ────────────────────────────────────────────────────────
-- 存储过程四：数据修改
-- 功能：按商品分类批量调整价格（涨价或降价）
-- 入参：p_category（分类名），p_pct（调价百分比，正数涨价，负数降价）
-- 出参：p_affected（实际更新的商品数量）
-- 示例：CALL UpdateProductPriceByCategory('数码', 5.00, @n) → 数码类涨价5%
-- ────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS UpdateProductPriceByCategory //
CREATE PROCEDURE UpdateProductPriceByCategory(
    IN  p_category VARCHAR(50),
    IN  p_pct      DECIMAL(5,2),
    OUT p_affected INT
)
BEGIN
    -- 校验调价幅度（防止调到负数）
    IF p_pct <= -100 THEN
        SET p_affected = 0;
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = '失败：降价幅度不能超过100%';
    ELSE
        UPDATE product
        SET price = ROUND(price * (1 + p_pct / 100), 2)
        WHERE category = p_category;

        SET p_affected = ROW_COUNT();
    END IF;
END //

DELIMITER ;

SELECT '✅ 四个存储过程创建完成' AS 进度;


-- ══════════════════════════════════════════════════════════
--  四、验证测试（执行后可检查结果是否符合预期）
-- ══════════════════════════════════════════════════════════

-- ── 测试触发器一（INSERT 前触发：自动计算金额）──────────────
-- 说明：下单时不传 total_amount，触发器自动填写
INSERT INTO orders (consumer_id, product_id, quantity)
VALUES (1, 1, 2);
-- 预期：新订单的 total_amount = 299.00 × 2 = 598.00
SELECT id, consumer_id, product_id, quantity, total_amount, status
FROM orders
ORDER BY id DESC LIMIT 1;


-- ── 测试触发器二（UPDATE 后触发：写审计日志）──────────────
-- 说明：修改刚刚插入的订单状态，应触发写入 audit_log
UPDATE orders SET status = '已完成'
WHERE id = (SELECT MAX(id) FROM (SELECT id FROM orders) tmp);
-- 预期：audit_log 出现一条 UPDATE 记录
SELECT id, action, table_name, record_id, old_value, new_value, op_time
FROM audit_log
ORDER BY op_time DESC LIMIT 3;


-- ── 测试触发器三（DELETE 前触发：保护已完成订单）──────────
-- 说明：尝试删除一条"已完成"订单，应报错
-- 以下语句预期报错：业务规则：禁止删除已完成或已发货的订单
-- DELETE FROM orders WHERE status = '已完成' LIMIT 1;

-- 说明：删除"已取消"订单应成功，且写入 audit_log
DELETE FROM orders WHERE status = '已取消' LIMIT 1;
SELECT id, action, table_name, record_id, old_value, op_time
FROM audit_log WHERE action = 'DELETE'
ORDER BY op_time DESC LIMIT 1;


-- ── 测试存储过程一（多表查询）──────────────────────────────
CALL GetOrdersByConsumerName('李娜');


-- ── 测试存储过程二（数据插入）──────────────────────────────
CALL InsertProduct('蓝牙音箱', 199.00, 50, '数码', '便携式蓝牙音箱，续航12小时', @res, @id);
SELECT @res AS 插入结果, @id AS 新商品ID;


-- ── 测试存储过程三（数据删除）──────────────────────────────
-- 删除30天前的已取消订单
CALL DeleteCancelledOrders(DATE_SUB(CURDATE(), INTERVAL 30 DAY), @cnt);
SELECT CONCAT('已删除 ', IFNULL(@cnt, 0), ' 条已取消订单') AS 删除结果;


-- ── 测试存储过程四（数据修改）──────────────────────────────
-- 数码类商品涨价 5%
CALL UpdateProductPriceByCategory('数码', 5.00, @n);
SELECT CONCAT('已更新 ', IFNULL(@n, 0), ' 件数码类商品价格') AS 调价结果;
-- 验证价格是否更新
SELECT id, name, price, category FROM product WHERE category = '数码';


-- ══════════════════════════════════════════════════════════
--  完成提示
-- ══════════════════════════════════════════════════════════
SELECT '============================================' AS 分隔线;
SELECT 'shop_supplement.sql 执行完成！'               AS 提示;
SELECT '新增内容：'                                    AS 说明;
SELECT '  ✅ audit_log 审计日志表'                     AS 内容1;
SELECT '  ✅ 触发器：trg_orders_before_insert（INSERT前）' AS 内容2;
SELECT '  ✅ 触发器：trg_orders_after_update（UPDATE后）'  AS 内容3;
SELECT '  ✅ 触发器：trg_orders_before_delete（DELETE前）' AS 内容4;
SELECT '  ✅ 存储过程：GetOrdersByConsumerName（多表查询）' AS 内容5;
SELECT '  ✅ 存储过程：InsertProduct（数据插入）'           AS 内容6;
SELECT '  ✅ 存储过程：DeleteCancelledOrders（数据删除）'   AS 内容7;
SELECT '  ✅ 存储过程：UpdateProductPriceByCategory（批量修改）' AS 内容8;
SELECT '============================================' AS 分隔线;
