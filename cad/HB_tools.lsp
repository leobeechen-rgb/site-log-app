;;; ==========================================================
;;;  赫柏工具 HB_tools.lsp     赫柏空間設計 HERFULSINS
;;;  只要記一個指令：HB  → 打開「赫柏工具」面板，全部用按鈕操作
;;;
;;;  面板內容
;;;    1. 出 PDF（這張圖）   每個配置頁各出一個 PDF
;;;    2. 出 PDF（整個資料夾） 資料夾裡每個 DWG 都出 PDF
;;;       → 存到圖檔所在資料夾的 PDF_OUTPUT
;;;       → DWG To PDF、ISO A3 橫式、1:1、出圖A3.ctb、不置中
;;;    3. 放水電符號        從自己的圖塊庫 DWG 選符號，點哪裡放哪裡
;;;    4. 圖例＋數量表      框選範圍，自動做出「圖例／名稱／數量」表格
;;;    5. 設定              指定圖塊庫 DWG、出圖樣式表
;;;    6. 軌道燈／拉伸軌道燈  點起點終點畫軌道燈，燈具自動等距；可再拉長縮短
;;;    7. 門片開門線        點門片框內部，自動畫開門虛線（左開／右開／對開／上掀／下掀）
;;;
;;;  安裝：APPLOAD → 啟動組（Startup Suite）→ 加入這個檔案
;;; ==========================================================

(vl-load-com)

;;; ---------- 設定（存在 Windows 登錄，下次開 CAD 還在） ----------
(defun hb:get (k d / v) (setq v (getenv k)) (if (and v (/= v "")) v d))
(defun hb:lib () (hb:get "HB_LIB" ""))
(defun hb:ctb () (hb:get "HB_CTB" "出圖A3.ctb"))
(setq hb:*device* "DWG To PDF.pc3")

(defun hb:say (s) (princ (strcat "\n【赫柏】" s)) (princ))

;;; ---------- 錯誤處理：還原系統變數 ----------
(defun hb:save-vars (lst)
  (setq hb:*vars* (mapcar '(lambda (v) (cons v (getvar v))) lst)))
(defun hb:restore-vars ()
  (foreach p hb:*vars* (vl-catch-all-apply 'setvar (list (car p) (cdr p))))
  (setq hb:*vars* nil))
(defun hb:err (msg)
  (while (> (getvar "CMDACTIVE") 0) (command))
  (if hb:*undo-open*
    (progn (vl-catch-all-apply 'vla-EndUndoMark (list (vla-get-ActiveDocument (vlax-get-acad-object))))
           (setq hb:*undo-open* nil)))
  (hb:restore-vars)
  (if (and msg (not (wcmatch (strcase msg) "*CANCEL*,*QUIT*,*EXIT*,*取消*")))
    (hb:say (strcat "發生錯誤：" msg)))
  (setq *error* hb:*olderr*)
  (princ))
(defun hb:begin (vars)
  (setq hb:*olderr* *error* *error* hb:err)
  (hb:save-vars vars))
(defun hb:end ()
  (hb:restore-vars)
  (setq *error* hb:*olderr*))

;;; ==========================================================
;;;  出 PDF
;;; ==========================================================

;;; 找出 A3 的紙張名稱（各語言版本的 AutoCAD 名稱不同，用程式問 CAD）
(defun hb:a3-media (/ doc pcs pc names canon loc)
  (if hb:*media* hb:*media*
    (progn
      (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
      (acad-push-dbmod)
      (setq pcs (vla-get-PlotConfigurations doc))
      (setq pc (vl-catch-all-apply 'vla-add (list pcs "HB_TMP_A3" :vlax-false)))
      (if (not (vl-catch-all-error-p pc))
        (progn
          (vl-catch-all-apply 'vla-put-ConfigName (list pc hb:*device*))
          (vl-catch-all-apply 'vla-RefreshPlotDeviceInfo (list pc))
          (setq names (vl-catch-all-apply
                        '(lambda () (vlax-safearray->list (vlax-variant-value (vla-GetCanonicalMediaNames pc))))))
          (if (vl-catch-all-error-p names) (setq names nil))
          (setq canon (or (car (vl-remove-if-not '(lambda (n) (wcmatch (strcase n) "ISO_FULL_BLEED_A3_(420*")) names))
                          (car (vl-remove-if-not '(lambda (n) (wcmatch (strcase n) "ISO_A3_(420*")) names))))
          (if canon (setq loc (vl-catch-all-apply 'vla-GetLocaleMediaName (list pc canon))))
          (if (vl-catch-all-error-p loc) (setq loc nil))
          (vl-catch-all-apply 'vla-delete (list pc))))
      (acad-pop-dbmod)
      (setq hb:*media* (if loc loc "ISO full bleed A3 (420.00 x 297.00 MM)")))))

;;; 依頁籤順序列出配置頁（不含模型）
(defun hb:layouts (/ doc lst)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (vlax-for l (vla-get-Layouts doc)
    (if (/= (strcase (vla-get-Name l)) "MODEL")
      (setq lst (cons (cons (vla-get-TabOrder l) (vla-get-Name l)) lst))))
  (mapcar 'cdr (vl-sort lst '(lambda (a b) (< (car a) (car b))))))

(defun hb:clean-name (s / bad)
  (setq bad '("\\" "/" ":" "*" "?" "\"" "<" ">" "|"))
  (foreach b bad (while (vl-string-search b s) (setq s (vl-string-subst "_" b s))))
  s)

;;; 出一個 PDF，完成回傳 T
(defun hb:plot1 (lay fn / media ok)
  (setq media (hb:a3-media))
  (if (findfile fn) (vl-file-delete fn))
  (if (= lay "Model")
    (command "_.-PLOT" "_Yes" "Model" hb:*device* media "_Millimeters" "_Landscape" "_No"
             "_Extents" "_Fit" "_Center" "_Yes" (hb:ctb) "_Yes" "" fn "_No" "_Yes")
    (command "_.-PLOT" "_Yes" lay hb:*device* media "_Millimeters" "_Landscape" "_No"
             "_Layout" "1:1" "0,0" "_Yes" (hb:ctb) "_Yes" "_No" "_No" "_No" fn "_No" "_Yes"))
  (setq ok (= (getvar "CMDACTIVE") 0))
  (while (> (getvar "CMDACTIVE") 0) (command))
  (and ok (findfile fn)))

;;; 這張圖的所有配置頁都出 PDF。silent=T 時不跳視窗（給批次用）
(defun hb:pdf-doc (silent / outdir base lays n okn fn fail)
  (setq outdir (strcat (getvar "DWGPREFIX") "PDF_OUTPUT"))
  (vl-mkdir outdir)
  (setq base (vl-filename-base (getvar "DWGNAME")))
  (setq lays (hb:layouts))
  (if (null lays) (setq lays '("Model")))
  (setq n 0 okn 0)
  (acad-push-dbmod)
  (foreach l lays
    (setq n (1+ n))
    (setq fn (strcat outdir "\\" (hb:clean-name base)
                     (if (> (length lays) 1) (strcat "_" (hb:clean-name l)) "") ".pdf"))
    (if (hb:plot1 l fn) (setq okn (1+ okn)) (setq fail (cons l fail))))
  (acad-pop-dbmod)
  (hb:say (strcat base "：完成 " (itoa okn) "／" (itoa n) " 張"
                  (if fail (strcat "，失敗：" (apply 'strcat (mapcar '(lambda (x) (strcat x " ")) fail))) "")))
  (if (and (not silent) (> okn 0))
    (progn
      (alert (strcat "PDF 完成 " (itoa okn) " 張"
                     (if fail (strcat "\n（" (itoa (length fail)) " 張失敗，請看指令列）") "")
                     "\n\n存在：\n" outdir))
      (vl-catch-all-apply 'startapp (list "explorer" (strcat "\"" outdir "\"")))))
  okn)

(defun hb:pdf-this ()
  (if (= (getvar "DWGTITLED") 0)
    (alert "這張圖還沒存檔。\n請先存檔，PDF 會放在圖檔旁邊的 PDF_OUTPUT 資料夾。")
    (progn
      (hb:begin '("BACKGROUNDPLOT" "CMDECHO" "FILEDIA"))
      (setvar "BACKGROUNDPLOT" 0) (setvar "CMDECHO" 0) (setvar "FILEDIA" 0)
      (hb:pdf-doc nil)
      (hb:end)))
  (princ))

;;; 整個資料夾：產生一個腳本，逐一開圖 → 出 PDF → 關圖（不存檔）
(defun hb:pdf-folder (/ pick dir files scr f bg)
  (setq pick (getfiled "選資料夾裡任何一個 DWG（會出這個資料夾全部的圖）" (getvar "DWGPREFIX") "dwg" 0))
  (if pick
    (progn
      (setq dir (vl-filename-directory pick))
      (setq files (vl-sort (vl-directory-files dir "*.dwg" 1) '<))
      (if (and files
               (= 6 (hb:yesno (strcat "這個資料夾有 " (itoa (length files)) " 個 DWG，要全部出 PDF 嗎？\n\n"
                                      dir "\n\n過程中 CAD 會自動開圖、關圖（不會存檔、不會改你的圖），請不要操作，等跑完。"))))
        (progn
          (setq scr (strcat (getvar "TEMPPREFIX") "HB_batch_pdf.scr"))
          (setq f (open scr "w"))
          (setq bg (getvar "BACKGROUNDPLOT"))
          (write-line "BACKGROUNDPLOT 0" f)
          (foreach d files
            (write-line "_.OPEN" f)
            (write-line (strcat "\"" dir "\\" d "\"") f)
            (write-line "(if hb:pdf-doc (progn (setvar \"CMDECHO\" 0) (hb:pdf-doc T)) (princ \"\\n【赫柏】這張圖沒有載入赫柏工具，請確認已加入啟動組\"))" f)
            (write-line "_.CLOSE" f))
          (write-line (strcat "BACKGROUNDPLOT " (itoa bg)) f)
          (write-line "(alert \"資料夾的 PDF 全部跑完了。\\n每張圖的 PDF 在圖檔旁的 PDF_OUTPUT 資料夾。\")" f)
          (close f)
          (command "_.SCRIPT" scr)))))
  (princ))

(defun hb:yesno (msg / sh r)
  (setq sh (vlax-create-object "WScript.Shell"))
  (setq r (vl-catch-all-apply 'vlax-invoke (list sh 'Popup msg 0 "赫柏工具" 36)))
  (vlax-release-object sh)
  (if (vl-catch-all-error-p r) 6 r))

;;; ==========================================================
;;;  圖塊庫（ObjectDBX 讀取，不用打開圖塊庫 DWG）
;;; ==========================================================
(defun hb:dbx-open (path / dbx r)
  (setq dbx (vl-catch-all-apply 'vla-GetInterfaceObject
              (list (vlax-get-acad-object)
                    (strcat "ObjectDBX.AxDbDocument." (substr (getvar "ACADVER") 1 2)))))
  (if (vl-catch-all-error-p dbx) nil
    (progn
      (setq r (vl-catch-all-apply 'vla-open (list dbx path :vlax-true)))
      (if (vl-catch-all-error-p r)
        (setq r (vl-catch-all-apply 'vla-open (list dbx path))))
      (if (vl-catch-all-error-p r) (progn (vlax-release-object dbx) nil) dbx))))

;;; 回傳 ((名稱 . 說明) ...)
;;; ---------- 圖塊庫命名（電_／水_／燈_／天_），舊名稱會自動整理 ----------
(setq hb:*renmap* '(
    ("110V插座" "電_110V插座" "新增110V插座")
    ("廚房" "電_110V廚房插座" "新增110V廚房插座")
    ("220v" "電_220V廚房插座" "新增220V廚房插座")
    ("083103" "電_戶外插座" "戶外插座")
    ("022003" "電_網路" "新增網路")
    ("022004" "電_電視" "新增電視")
    ("T" "電_電話" "新增電話")
    ("CCC" "電_冷氣供電" "冷氣供電")
    ("SS" "電_暖風機面板" "暖風機面板")
    ("水" "水_冷水" "新增冷水")
    ("排水" "水_排水" "排水")
    ("糞" "水_糞管" "新增糞管")
    ("壁面排水" "水_壁面排水" "壁面排水")
    ("FS" "水_化糞池預埋" "化糞池預埋（留清潔口）")
    ("崁燈15cm" "燈_崁燈15cm" "崁燈（15cm）")
    ("崁燈9cm" "燈_崁燈9cm" "崁燈（9cm）")
    ("吸頂燈" "燈_吸頂燈" "吸頂燈／筒燈")
    ("投射燈" "燈_投射燈" "投射燈")
    ("吊燈" "燈_吊燈" "吊燈")
    ("壁燈" "燈_壁燈" "壁燈")
    ("鋁槽燈1x1" "燈_鋁槽燈1x1" "鋁槽燈（1×1）")
    ("軌道燈1m" "燈_軌道燈1m" "軌道燈（每段 1m）")
    ("軌道燈出線" "燈_軌道燈出線" "軌道燈出線")
    ("間接照明" "燈_間接照明" "間接照明")
    ("F" "天_暖風機" "暖風機")
    ("浴室抽風機" "天_浴室抽風機" "浴室抽風機")
    ("維修孔45" "天_維修孔45" "維修孔（45×45）")
    ("冷氣出風口" "天_冷氣出風口" "冷氣出風口")
    ("冷氣回風口" "天_冷氣回風口" "冷氣回風口")
    ("偵煙器" "天_偵煙器" "偵煙器")
    ("灑水頭" "天_灑水頭" "灑水頭")
))

;;; 圖塊的「指紋」：裡面各種物件各幾個。用來確認舊圖的同名圖塊真的是同一個符號
(defun hb:fp (blk / lst k c)
  (vlax-for e blk
    (setq k (vla-get-ObjectName e))
    (if (setq c (assoc k lst)) (setq lst (subst (cons k (1+ (cdr c))) c lst)) (setq lst (cons (cons k 1) lst))))
  (apply 'strcat (mapcar '(lambda (x) (strcat (car x) "=" (itoa (cdr x)) ";"))
                         (vl-sort lst '(lambda (a b) (< (car a) (car b)))))))

(defun hb:blk (blks name / b)
  (setq b (vl-catch-all-apply 'vla-item (list blks name)))
  (if (vl-catch-all-error-p b) nil b))

;;; 對一個圖面資料庫做改名。fps＝圖塊庫的指紋表（nil＝不檢查）。回傳 (改了幾個 . 跳過清單)
(defun hb:rename-in (blks fps / ok skip b fp)
  (setq ok 0)
  (foreach x hb:*renmap*
    (cond
      ((setq b (hb:blk blks (car x)))
       (setq fp (cdr (assoc (car x) fps)))
       (cond
         ((hb:blk blks (cadr x)) (setq skip (cons (strcat (car x) "（新名稱已存在）") skip)))
         ((and fps (or (null fp) (/= fp (hb:fp b)))) (setq skip (cons (strcat (car x) "（圖形不同，沒改）") skip)))
         ((vl-catch-all-error-p (vl-catch-all-apply 'vla-put-Name (list b (cadr x))))
          (setq skip (cons (car x) skip)))
         (T (vl-catch-all-apply 'vla-put-Comments (list b (caddr x))) (setq ok (1+ ok)))))
      ((setq b (hb:blk blks (cadr x)))
       (if (= (vla-get-Comments b) "") (vl-catch-all-apply 'vla-put-Comments (list b (caddr x)))))))
  (cons ok skip))


;;; 回傳 ((名稱 . 說明) ...)，依「電、水、燈、天」排序，系統圖塊（_開頭）不列
(setq hb:*cats* '("電" "水" "燈" "天"))
;;; 用 wcmatch／strlen 判斷，AutoCAD 2016（Big5 雙位元組）和新版都正確
(defun hb:cat-of (n / r)
  (foreach c hb:*cats* (if (and (null r) (wcmatch n (strcat c "_*"))) (setq r c)))
  r)
(defun hb:cat-rank (n / c)
  (if (setq c (hb:cat-of n)) (vl-position c hb:*cats*) 9))
(defun hb:lib-blocks (/ lib dbx lst)
  (setq lib (hb:lib))
  (if (and (/= lib "") (findfile lib) (setq dbx (hb:dbx-open lib)))
    (progn
      (vlax-for b (vla-get-Blocks dbx)
        (if (and (= (vla-get-IsLayout b) :vlax-false)
                 (= (vla-get-IsXRef b) :vlax-false)
                 (not (wcmatch (vla-get-Name b) "`**,*|*,_*")))
          (setq lst (cons (cons (vla-get-Name b) (vla-get-Comments b)) lst))))
      (vlax-release-object dbx)
      (vl-sort lst '(lambda (a b) (if (= (hb:cat-rank (car a)) (hb:cat-rank (car b)))
                                     (< (car a) (car b))
                                     (< (hb:cat-rank (car a)) (hb:cat-rank (car b)))))))))

;;; 清單上顯示的文字：「電｜新增110V插座」
(defun hb:label (b / n d c)
  (setq n (car b) d (cdr b) c (hb:cat-of n))
  (if c
    (strcat c "｜" (if (and d (/= d "")) d (substr n (1+ (strlen (strcat c "_"))))))
    (if (and d (/= d "")) (strcat n "｜" d) n)))

;;; 圖塊庫還是舊名稱的話，問要不要自動整理（會先備份）
(defun hb:lib-tidy (/ lib dbx old doc r bak opened)
  (setq lib (hb:lib))
  (if (and (/= lib "") (findfile lib) (setq dbx (hb:dbx-open lib)))
    (progn
      (foreach x hb:*renmap* (if (hb:blk (vla-get-Blocks dbx) (car x)) (setq old (cons (car x) old))))
      (vlax-release-object dbx) (setq dbx nil)
      (if (and old (= 6 (hb:yesno (strcat "圖塊庫裡還有 " (itoa (length old)) " 個符號是舊名稱（例如 " (car old) "）。\n\n"
                                          "要現在自動整理成「電／水／燈／天」的清楚名稱嗎？\n原檔會先備份一份。"))))
        (progn
          (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
          (vlax-for d (vla-get-Documents (vlax-get-acad-object))
            (if (= (strcase (vla-get-FullName d)) (strcase lib)) (setq opened d)))
          (cond
            ((and opened (equal opened doc))
             (setq r (hb:rename-in (vla-get-Blocks doc) nil))
             (vla-Save doc)
             (alert (strcat "整理好了：" (itoa (car r)) " 個符號，圖塊庫已存檔。")))
            (opened
             (alert "圖塊庫目前在 CAD 裡開著。\n請先切到那張圖存檔關掉，再按一次「放水電符號」。"))
            ((setq dbx (hb:dbx-open lib))
             (setq bak (strcat (vl-filename-directory lib) "\\" (vl-filename-base lib) "_整理前備份.dwg"))
             (if (not (findfile bak)) (vl-file-copy lib bak))
             (setq r (hb:rename-in (vla-get-Blocks dbx) nil))
             (if (vl-catch-all-error-p (vl-catch-all-apply 'vla-SaveAs (list dbx lib)))
               (alert "圖塊庫存檔失敗（可能是唯讀或別人開著），名稱沒有改。")
               (alert (strcat "整理好了：" (itoa (car r)) " 個符號。\n原檔備份：" bak)))
             (vlax-release-object dbx))))))))

;;; 把圖塊定義從圖塊庫複製進目前的圖
(defun hb:import-block (name / doc dbx blk arr ok)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (if (tblsearch "BLOCK" name) T
    (if (setq dbx (hb:dbx-open (hb:lib)))
      (progn
        (setq blk (vl-catch-all-apply 'vla-item (list (vla-get-Blocks dbx) name)))
        (if (not (vl-catch-all-error-p blk))
          (progn
            (setq arr (vlax-make-safearray vlax-vbObject '(0 . 0)))
            (vlax-safearray-put-element arr 0 blk)
            (setq ok (not (vl-catch-all-error-p
                            (vl-catch-all-apply 'vla-CopyObjects (list dbx arr (vla-get-Blocks doc))))))))
        (vlax-release-object dbx)
        (and ok (tblsearch "BLOCK" name))))))

(defun hb:need-lib ()
  (if (and (/= (hb:lib) "") (findfile (hb:lib))) T
    (progn
      (alert "還沒指定圖塊庫。\n\n按「確定」後，請選你放水電符號的那個 DWG 檔。")
      (hb:set-lib)
      (and (/= (hb:lib) "") (findfile (hb:lib))))))

(defun hb:set-lib (/ f)
  (setq f (getfiled "選擇圖塊庫 DWG（放水電符號的檔案）" (if (/= (hb:lib) "") (hb:lib) "") "dwg" 0))
  (if f (progn (setenv "HB_LIB" f) (hb:say (strcat "圖塊庫：" f))))
  (princ))

;;; ==========================================================
;;;  放水電符號
;;; ==========================================================
;;; 插入後檢查：圖塊的基準點如果離圖形很遠（圖塊庫裡畫的位置不在原點附近），
;;; 符號會出現在別的地方 → 自動把圖形中心移到點的位置。
(defun hb:fix-offset (ref pw / mn mx a b c d dx dy)
  (if (not (vl-catch-all-error-p (vl-catch-all-apply 'vla-GetBoundingBox (list ref 'mn 'mx))))
    (progn
      (setq a (vlax-safearray->list mn) b (vlax-safearray->list mx)
            c (list (/ (+ (car a) (car b)) 2.0) (/ (+ (cadr a) (cadr b)) 2.0) (caddr pw))
            d (max (- (car b) (car a)) (- (cadr b) (cadr a)) 1e-6)
            dx (- (car pw) (car c)) dy (- (cadr pw) (cadr c)))
      ;; 點的位置落在圖形範圍外超過一個符號大小，就視為基準點跑掉
      (if (or (< (car pw) (- (car a) d)) (> (car pw) (+ (car b) d))
              (< (cadr pw) (- (cadr a) d)) (> (cadr pw) (+ (cadr b) d)))
        (progn
          (vla-Move ref (vlax-3d-point c) (vlax-3d-point pw))
          (setq hb:*offset-fixed* (1+ hb:*offset-fixed*)))))))

;;; ==========================================================
;;;  安裝高度：符號右邊標「H30」（離地公分）
;;;  放符號時會問；已經放好的可用面板「加安裝高度」或指令 HBH 補標
;;; ==========================================================
(setq hb:*hmap* nil)
(defun hb:h-default (name / v)
  (cond ((setq v (cdr (assoc name hb:*hmap*))) v)
        ((wcmatch name "*開關*") "120")
        ((wcmatch name "*冷氣*") "210")
        (T "30")))

(defun hb:h-text (ref h / doc sp mn mx a b th tx)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (if (and (not (vl-catch-all-error-p (vl-catch-all-apply 'vla-GetBoundingBox (list ref 'mn 'mx))))
           (setq sp (vl-catch-all-apply 'vla-ObjectIDToObject (list doc (vla-get-OwnerID ref))))
           (not (vl-catch-all-error-p sp)))
    (progn
      (setq a (vlax-safearray->list mn) b (vlax-safearray->list mx)
            th (max 1.0 (* 0.42 (- (cadr b) (cadr a)))))
      (setq tx (vla-AddText sp (strcat "H" h)
                 (vlax-3d-point (list (+ (car b) (* 0.25 th)) (- (/ (+ (cadr a) (cadr b)) 2.0) (/ th 2.0)) 0.0)) th))
      (vl-catch-all-apply 'vla-put-Height (list tx th))
      (vla-put-Layer tx (vla-get-Layer ref))
      tx)))

;;; 問高度：Enter = 預設、0 = 不標；回傳字串或 nil
(defun hb:h-ask (name / d s)
  (setq d (hb:h-default name))
  (setq s (getstring (strcat "\n安裝高度（離地公分，例如 30、110；打 0 不標）<" d ">：")))
  (if (= s "") (setq s d))
  (setq hb:*hmap* (cons (cons name s) (vl-remove-if '(lambda (x) (= (car x) name)) hb:*hmap*)))
  (if (member s '("0" "N" "n")) nil s))

;;; 已經放好的符號：框選後一次補標
(defun hb:h-batch (/ ss i h n)
  (princ "\n框選要標安裝高度的插座、開關…")
  (if (setq ss (ssget '((0 . "INSERT"))))
    (progn
      (setq h (getstring "\n安裝高度（離地公分）<30>："))
      (if (= h "") (setq h "30"))
      (setq i 0 n 0)
      (repeat (sslength ss)
        (if (hb:h-text (vlax-ename->vla-object (ssname ss i)) h) (setq n (1+ n)))
        (setq i (1+ i)))
      (hb:say (strcat "已標 " (itoa n) " 個符號：H" h))))
  (princ))
(defun c:HBH () (hb:h-batch))

;;; 放符號的比例（預設 1，可在點位置時打 S 修改，會記住）
(defun hb:psc () (atof (hb:get "HB_PSCALE" "1")))

(defun hb:place (name / p pw e ref ang sc iu hh)
  (if (hb:import-block name)
    (progn
      (hb:begin '("ATTREQ" "CMDECHO" "ATTDIA" "INSUNITS" "INSUNITSDEFSOURCE" "INSUNITSDEFTARGET"))
      (setvar "ATTREQ" 0) (setvar "CMDECHO" 0) (setvar "ATTDIA" 0)
      ;; 關掉「單位自動換算」：圖塊庫和這張圖的單位設定不同時（例如一個 mm、一個 cm），
      ;; CAD 會自動放大 10 倍，基準點的偏移也跟著放大，符號就會又大又跑位。
      (setvar "INSUNITS" 0) (setvar "INSUNITSDEFSOURCE" 0) (setvar "INSUNITSDEFTARGET" 0)
      (setq hb:*offset-fixed* 0)
      (while (progn
               (setq sc (hb:psc))
               (if (<= sc 0) (setq sc 1.0))
               (initget "S")
               (setq p (getpoint (strcat "\n放「" name "」：點位置，或 [比例(S)]  目前比例 " (rtos sc 2 2) "（按 Enter 結束）")))
               (if (= p "S")
                 (progn
                   (initget 6)
                   (setq sc (getreal (strcat "\n新的比例（例如 0.1、0.5、2）<" (rtos (hb:psc) 2 2) ">：")))
                   (if sc (setenv "HB_PSCALE" (rtos sc 2 4)))
                   T)
                 p))
        (if (listp p)
          (progn
            (setq e (entlast))
            ;; 先指定比例、角度 0 再點位置，任何圖塊（含統一比例）都不會多問問題
            (command "_.-INSERT" name "_S" (rtos sc 2 4) "_R" "0" "_non" p)
            (while (> (getvar "CMDACTIVE") 0) (command ""))
            (if (and (setq e (if e (entnext e) (entlast)))
                     (setq e (progn (while (and e (/= (cdr (assoc 0 (entget e))) "INSERT")) (setq e (entnext e))) e)))
              (progn
                (setq ref (vlax-ename->vla-object e)
                      pw  (trans p 1 0))
                (hb:fix-offset ref pw)
                (setq ang (getangle p "\n轉角度：移動滑鼠點一下，或直接按 Enter = 0 度"))
                (if (and ang (/= ang 0.0))
                  (vla-Rotate ref (vlax-3d-point pw) ang))
                (if (setq hh (hb:h-ask name)) (hb:h-text ref hh)))))))
      (if (> hb:*offset-fixed* 0)
        (hb:say (strcat "「" name "」的基準點離圖形太遠，已自動放到你點的位置。"
                        "（要根治：到圖塊庫用 BEDIT 開這個圖塊，BASE 把基準點設在符號中心）")))
      (hb:end))
    (alert (strcat "圖塊庫裡找不到「" name "」。")))
  (princ))

;;; ==========================================================
;;;  圖例＋數量表
;;; ==========================================================
;;; 不重複的名稱清單（最多 8 個）
(defun hb:name-list (lst / u n out)
  (foreach x lst (if (not (member x u)) (setq u (cons x u))))
  (setq n 0 out "")
  (foreach x (vl-sort u '<) (if (< n 8) (setq out (strcat out "\n‧" x) n (1+ n))))
  (if (= out "") "（沒有）" (if (> (length u) 8) (strcat out "\n…") out)))

;;; 圖塊名稱（動態圖塊用原始名稱）
(defun hb:ref-name (ent / nm)
  (setq nm (vl-catch-all-apply 'vla-get-EffectiveName (list ent)))
  (if (vl-catch-all-error-p nm) (vla-get-Name ent) nm))

;;; 數一個圖塊參考：本身是圖塊庫符號就算 1；不是的話往裡面找（整張平面圖做成圖塊、或用複製貼上的群組）
(defun hb:count-ref (ent libnames depth / nm blk)
  (setq nm (hb:ref-name ent))
  (cond
    ((wcmatch nm "`**,*|*")
     ;; 匿名圖塊／外部參考：往裡面找
     (if (< depth 4) (hb:count-in (vla-get-Name ent) libnames depth)))
    ((or (null libnames) (member (hb:smart-base nm) libnames))
     (hb:add-cnt nm 1))
    (T
     ;; 不在圖塊庫的圖塊（例如自己畫的燈具）：記下來讓使用者勾選要不要列入
     (hb:add-other nm)
     (if (< depth 4) (hb:count-in (vla-get-Name ent) libnames depth)))))

(defun hb:add-other (nm / c)
  (if (setq c (assoc nm hb:*other*))
    (setq hb:*other* (subst (cons nm (1+ (cdr c))) c hb:*other*))
    (setq hb:*other* (cons (cons nm 1) hb:*other*))))

;;; 圖塊在這張圖裡的說明（Comments）
(defun hb:bdesc (nm / b)
  (setq b (vl-catch-all-apply 'vla-item (list (vla-get-Blocks (vla-get-ActiveDocument (vlax-get-acad-object))) nm)))
  (if (vl-catch-all-error-p b) "" (vla-get-Comments b)))

;;; 在圖上把某種圖塊全部亮起來（看看是哪個燈）
(defun hb:show-blk (nm / ss all i e n)
  (setq all (ssget "_X" (list '(0 . "INSERT") (cons 410 (getvar "CTAB")))) ss (ssadd) i 0 n 0)
  (if all
    (repeat (sslength all)
      (setq e (ssname all i) i (1+ i))
      (if (= (hb:ref-name (vlax-ename->vla-object e)) nm) (progn (ssadd e ss) (setq n (1+ n))))))
  (if (> n 0)
    (progn (sssetfirst nil ss)
           (getstring (strcat "\n「" nm "」共 " (itoa n) " 個，已在圖上亮起來（藍色夾點）。看完按 Enter 回到清單…"))
           (sssetfirst nil nil))
    (getstring (strcat "\n「" nm "」在別的圖塊裡面，沒辦法單獨亮起來。按 Enter 回到清單…"))))

;;; 勾選要一起列入的其他圖塊（燈具類預設勾好）
(defun hb:pick-others (lst / id items sel pre i r d nm out)
  (setq items (vl-sort lst '(lambda (a b) (< (car a) (car b)))))
  (setq i 0 pre "")
  (foreach x items
    (if (wcmatch (strcase (strcat (car x) (hb:bdesc (car x)))) "*燈*,*LIGHT*,*LAMP*,*嵌*,*崁*,*筒*,*吸頂*,*吊*,*DOWN*,*SPOT*")
      (setq pre (strcat pre (itoa i) " ")))
    (setq i (1+ i)))
  (setq sel (vl-string-right-trim " " pre) r 2)
  (while (= r 2)
    (setq id (load_dialog (hb:write-dcl)))
    (if (new_dialog "hb_pick" id)
      (progn
        (start_list "lst")
        (foreach x items
          (setq d (hb:bdesc (car x)))
          (add_list (strcat (if (/= d "") (strcat d "　〔" (car x) "〕") (car x)) "　（" (itoa (cdr x)) " 個）")))
        (end_list)
        (if (/= sel "") (set_tile "lst" sel))
        (action_tile "lst" "(setq sel $value)")
        (action_tile "all" "(setq sel (hb:all-idx (length items))) (set_tile \"lst\" sel)")
        (action_tile "show" "(setq sel (get_tile \"lst\")) (done_dialog 2)")
        (setq r (start_dialog)))
      (setq r 0))
    (unload_dialog id)
    (if (= r 2)
      (if (and sel (/= sel ""))
        (hb:show-blk (car (nth (car (read (strcat "(" sel ")"))) items)))
        (alert "先在清單點一個，再按「在圖上看是哪個」。"))))
  (if (and (= r 1) sel (/= sel ""))
    (progn
      (foreach k (read (strcat "(" sel ")"))
        (setq nm (car (nth k items)))
        ;; 沒有中文名稱的（例如 DBB、FBFD）→ 問一次要叫什麼，記在這張圖裡
        (if (= (hb:bdesc nm) "")
          (progn
            (hb:show-blk-quiet nm)
            (setq d (getstring T (strcat "\n「" nm "」（已亮起來）在表格要叫什麼？例如 崁燈、吊燈 <" nm ">：")))
            (sssetfirst nil nil)
            (if (/= d "")
              (vl-catch-all-apply 'vla-put-Comments
                (list (vla-item (vla-get-Blocks (vla-get-ActiveDocument (vlax-get-acad-object))) nm) d)))))
        (setq out (cons (nth k items) out)))
      (reverse out))))

(defun hb:show-blk-quiet (nm / ss all i e)
  (setq all (ssget "_X" (list '(0 . "INSERT") (cons 410 (getvar "CTAB")))) ss (ssadd) i 0)
  (if all
    (repeat (sslength all)
      (setq e (ssname all i) i (1+ i))
      (if (= (hb:ref-name (vlax-ename->vla-object e)) nm) (ssadd e ss))))
  (if (> (sslength ss) 0) (sssetfirst nil ss)))

(defun hb:all-idx (n / i s)
  (setq i 0 s "")
  (repeat n (setq s (strcat s (itoa i) " ") i (1+ i)))
  (vl-string-right-trim " " s))

(defun hb:count-in (bname libnames depth / blk)
  (setq blk (vl-catch-all-apply 'vla-item (list (vla-get-Blocks (vla-get-ActiveDocument (vlax-get-acad-object))) bname)))
  (if (not (vl-catch-all-error-p blk))
    (vlax-for o blk
      (if (= (vla-get-ObjectName o) "AcDbBlockReference")
        (hb:count-ref o libnames (1+ depth))))))

(defun hb:add-cnt (nm k / c)
  (if (setq c (assoc nm hb:*cnt*))
    (setq hb:*cnt* (subst (cons nm (+ k (cdr c))) c hb:*cnt*))
    (setq hb:*cnt* (cons (cons nm k) hb:*cnt*))))

;;; 表格一列的圖例：圖塊名稱有的話放圖塊圖示，沒有（軌道燈）就寫文字
(defun hb:cell-sym (tbl r nm doc / bdef id)
  (if (= nm "*TRACK*")
    (progn (vla-SetText tbl r 0 "─○─○─") (vla-SetCellAlignment tbl r 0 5))
    (progn
      (setq bdef (vl-catch-all-apply 'vla-item (list (vla-get-Blocks doc) nm)))
      (if (not (vl-catch-all-error-p bdef))
        (progn
          (setq id (vl-catch-all-apply 'vla-get-ObjectID32 (list bdef)))
          (if (vl-catch-all-error-p (vl-catch-all-apply 'vla-SetBlockTableRecordId32 (list tbl r 0 id :vlax-true)))
            (vl-catch-all-apply 'vla-SetBlockTableRecordId (list tbl r 0 (vla-get-ObjectID bdef) :vlax-true))))))))

;;; rows：((圖塊名 名稱 數量文字) ...)
(defun hb:put-rows (tbl r0 rows doc / r)
  (setq r r0)
  (foreach x rows
    (hb:cell-sym tbl r (nth 0 x) doc)
    (vla-SetText tbl r 1 (nth 1 x))
    (if (> (vla-get-Columns tbl) 2) (progn (vla-SetText tbl r 2 (nth 2 x)) (vla-SetCellAlignment tbl r 2 5)))
    (setq r (1+ r))))

;;; 填進現有表格：找到「數量」那一列當表頭，下面的列全部重做
(defun hb:fill-table (tbl rows doc / hr nr c r rh)
  (setq nr (vla-get-Rows tbl) r 0)
  (while (and (< r nr) (null hr))
    (setq c 0)
    (repeat (vla-get-Columns tbl)
      (if (wcmatch (vla-GetText tbl r c) "*數量*,*名稱*,*圖例*") (setq hr r))
      (setq c (1+ c)))
    (if (and hr (= (vla-GetText tbl hr 0) "水電圖例")) (setq hr nil))
    (setq r (1+ r)))
  (if (null hr) (setq hr 1))
  (setq rh (vla-GetRowHeight tbl (min (1+ hr) (1- nr))))
  (if (> (- nr hr 1) 0) (vla-DeleteRows tbl (1+ hr) (- nr hr 1)))
  (if rows (vla-InsertRows tbl (1+ hr) rh (length rows)))
  (hb:put-rows tbl (1+ hr) rows doc))

;;; 勾選要放進圖例表的符號（圖面上有的先勾好、帶數量）
(defun hb:leg-pick (items / id sel r i pre)
  (setq i 0 pre "")
  (foreach x items (if (> (nth 3 x) 0) (setq pre (strcat pre (itoa i) " "))) (setq i (1+ i)))
  (setq sel (vl-string-right-trim " " pre))
  (setq id (load_dialog (hb:write-dcl)))
  (if (new_dialog "hb_leg" id)
    (progn
      (start_list "lst")
      (foreach x items
        (add_list (strcat (nth 1 x) (if (> (nth 3 x) 0) (strcat "　…　" (nth 2 x)) "") (if (nth 4 x) "　〔圖面上其他圖塊〕" ""))))
      (end_list)
      (if (/= sel "") (set_tile "lst" sel))
      (action_tile "lst" "(setq sel $value)")
      (action_tile "all" "(setq sel (hb:all-idx (length items))) (set_tile \"lst\" sel)")
      (action_tile "none" "(setq sel \"\") (set_tile \"lst\" \"\")")
      (setq r (start_dialog))))
  (unload_dialog id)
  (if (and (= r 1) sel (/= sel ""))
    (mapcar '(lambda (k) (nth k items)) (read (strcat "(" sel ")")))
    (if (= r 1) 'none)))

;;; 用線和文字畫圖例表：欄寬 圖例 6h｜名稱 14h｜數量 5h，列高 2.4h
(defun hb:draw-legend (p0 rows h doc / sp x0 y0 w1 w2 w3 rh n W H y r add-l add-t ref bb mn mx sc c tw)
  (setq sp (if (= (getvar "CVPORT") 1) (vla-get-PaperSpace doc) (vla-get-ModelSpace doc)))
  (setq x0 (car p0) y0 (cadr p0) w1 (* 6 h) w2 (* 14 h) w3 (* 5 h) rh (* 2.4 h)
        n (+ 2 (length rows)) W (+ w1 w2 w3) H (* n rh))
  (defun add-l (a b) (vla-AddLine sp (vlax-3d-point (list (car a) (cadr a) 0.0)) (vlax-3d-point (list (car b) (cadr b) 0.0))))
  (defun add-t (s x y hh / t1)
    (setq t1 (vla-AddText sp s (vlax-3d-point (list x y 0.0)) hh))
    (if (tblsearch "STYLE" "赫柏-中文") (vl-catch-all-apply 'vla-put-StyleName (list t1 "赫柏-中文")))
    ;; 字型樣式如果設了固定字高，會把字放大 → 強制改回指定字高、寬度 1
    (vl-catch-all-apply 'vla-put-Height (list t1 hh))
    (vl-catch-all-apply 'vla-put-ScaleFactor (list t1 1.0))
    (vla-put-Alignment t1 10) ; 正中
    (vla-put-TextAlignmentPoint t1 (vlax-3d-point (list x y 0.0)))
    t1)
  ;; 外框與橫線
  (setq r 0)
  (repeat (1+ n)
    (add-l (list x0 (- y0 (* r rh))) (list (+ x0 W) (- y0 (* r rh))))
    (setq r (1+ r)))
  (add-l (list x0 y0) (list x0 (- y0 H)))
  (add-l (list (+ x0 W) y0) (list (+ x0 W) (- y0 H)))
  ;; 直線（標題列不分格）
  (add-l (list (+ x0 w1) (- y0 rh)) (list (+ x0 w1) (- y0 H)))
  (add-l (list (+ x0 w1 w2) (- y0 rh)) (list (+ x0 w1 w2) (- y0 H)))
  ;; 標題、表頭
  (add-t "水電圖例" (+ x0 (/ W 2.0)) (- y0 (* 0.5 rh)) (* 1.15 h))
  (add-t "圖例" (+ x0 (/ w1 2.0)) (- y0 (* 1.5 rh)) h)
  (add-t "名稱" (+ x0 w1 (/ w2 2.0)) (- y0 (* 1.5 rh)) h)
  (add-t "數量" (+ x0 w1 w2 (/ w3 2.0)) (- y0 (* 1.5 rh)) h)
  ;; 每一列
  (setq r 2)
  (foreach x rows
    (setq c (list (+ x0 (/ w1 2.0)) (- y0 (* (+ r 0.5) rh)) 0.0))
    (if (= (nth 0 x) "*TRACK*")
      (add-t "─○─○─" (car c) (cadr c) h)
      (if (tblsearch "BLOCK" (nth 0 x))
        (progn
          ;; 放一個符號，縮放到格子高度的 65%
          (setq ref (vla-InsertBlock sp (vlax-3d-point c) (nth 0 x) 1.0 1.0 1.0 0.0))
          (if (not (vl-catch-all-error-p (vl-catch-all-apply 'vla-GetBoundingBox (list ref 'mn 'mx))))
            (progn
              (setq mn (vlax-safearray->list mn) mx (vlax-safearray->list mx)
                    bb (max (- (car mx) (car mn)) (- (cadr mx) (cadr mn)) 1e-6)
                    sc (/ (* 0.65 rh) bb))
              (vla-ScaleEntity ref (vlax-3d-point c) sc)
              (vla-GetBoundingBox ref 'mn 'mx)
              (setq mn (vlax-safearray->list mn) mx (vlax-safearray->list mx))
              (vla-Move ref (vlax-3d-point (list (/ (+ (car mn) (car mx)) 2.0) (/ (+ (cadr mn) (cadr mx)) 2.0) 0.0))
                            (vlax-3d-point c)))))))
    (add-t (nth 1 x) (+ x0 w1 (/ w2 2.0)) (cadr c) h)
    (if (/= (nth 2 x) "") (add-t (nth 2 x) (+ x0 w1 w2 (/ w3 2.0)) (cadr c) h))
    (setq r (1+ r)))
  (princ))

;;; ==========================================================
;;;  圖例＋數量表（不用框選）：
;;;  自動數這一頁 → 清單列出圖塊庫全部符號（圖面上有的已勾、帶數量）→ 勾選 → 做表或填進現有表格
;;; ==========================================================
(defun hb:legend (/ doc libdesc libnames ss i e ent ti trklen trkn trkc items c d pk pt h tbl space rows pick)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (hb:begin '("CMDECHO"))
  (setvar "CMDECHO" 0)
  (if (and (/= (hb:lib) "") (findfile (hb:lib)))
    (setq libdesc (hb:lib-blocks) libnames (mapcar 'car libdesc)))
  ;; 1. 數這一頁（含圖塊裡面的）
  (setq trklen 0.0 trkn 0 trkc 0 hb:*cnt* nil hb:*other* nil)
  (setq ss (ssget "_X" (list '(-4 . "<OR") '(0 . "INSERT") '(0 . "LWPOLYLINE") '(-4 . "OR>") (cons 410 (getvar "CTAB")))))
  (if ss
    (progn
      (setq i 0)
      (repeat (sslength ss)
        (setq e (ssname ss i) ent (vlax-ename->vla-object e) i (1+ i))
        (if (/= (vla-get-ObjectName ent) "AcDbBlockReference")
          (if (setq ti (hb:trk-info e))
            (setq trklen (+ trklen (distance (nth 0 ti) (nth 1 ti))) trkn (+ trkn (nth 2 ti)) trkc (1+ trkc)))
          (hb:count-ref ent libnames 0)))))
  ;; 2. 清單項目：(圖塊名 顯示名稱 數量文字 數量 其他?)
  (foreach b (vl-remove-if '(lambda (x) (wcmatch (car x) "*_智能")) libdesc)
    (setq c (+ (cond ((cdr (assoc (car b) hb:*cnt*))) (0)) (cond ((cdr (assoc (strcat (car b) "_智能") hb:*cnt*))) (0))))
    (setq items (cons (list (car b) (hb:label b) (strcat (itoa c) " 個") c nil) items)))
  (setq items (reverse items))
  (if (> trkc 0)
    (setq items (cons (list "*TRACK*" (strcat "軌道燈（" (itoa trkc) " 條，合計 L=" (rtos trklen 2 0) "）") (strcat (itoa trkn) " 盞") trkn nil) items)))
  (foreach o (vl-sort hb:*other* '(lambda (a b) (< (car a) (car b))))
    (setq d (hb:bdesc (car o)))
    (setq items (append items (list (list (car o) (if (/= d "") d (car o)) (strcat (itoa (cdr o)) " 個") 0 T)))))
  (if (null items)
    (alert "沒有可以列的符號。\n請先在 HB 面板「指定圖塊庫」。")
    (progn
      ;; 3. 勾選
      (setq pick (hb:leg-pick items))
      (cond
        ((null pick) (princ "\n已取消。"))
        ((= pick 'none) (alert "沒有勾選任何符號。"))
        (T
         ;; 圖塊庫的符號匯進這張圖，表格才放得了圖示
         (foreach x pick (if (and (null (nth 4 x)) (/= (car x) "*TRACK*")) (hb:import-block (car x))))
         (setq rows (mapcar '(lambda (x / nm)
                               (list (car x)
                                     (if (nth 4 x) (nth 1 x)
                                       (if (= (car x) "*TRACK*") (nth 1 x)
                                         (cond ((/= (cdr (assoc (car x) libdesc)) "") (cdr (assoc (car x) libdesc))) (T (car x)))))
                                     (if (nth 4 x) (vl-string-subst "" " 個" (nth 2 x))
                                       (if (> (nth 3 x) 0) (if (= (car x) "*TRACK*") (nth 2 x) (itoa (nth 3 x))) ""))))
                            pick))
         ;; 指令列也列出數量，方便核對
         (princ "\n—— 圖例表內容 ——")
         (foreach r rows (princ (strcat "\n  " (nth 1 r) "：" (if (= (nth 2 r) "") "（空白）" (nth 2 r)))))
         ;; 4. 直接畫出圖例表（線＋文字＋符號，不用 CAD 表格，大小一定看得到）
         (setq pt (getpoint "\n點圖例表要放的位置（左上角）："))
         (if pt
           (progn
             (initget 6)
             (setq h (getreal (strcat "\n字高 <" (if (= (getvar "CVPORT") 1) "3.5" "12") ">：")))
             (if (null h) (setq h (if (= (getvar "CVPORT") 1) 3.5 12.0)))
             (hb:draw-legend (trans pt 1 0) rows h doc)
             (hb:say "圖例表完成。數量是現在圖面上的數量，改圖後刪掉再做一次。")))))))
  (hb:end)
  (princ))

;;; ==========================================================
;;;  赫柏樣板：單位、圖層、字型、標註、A3 出圖頁、圖框
;;; ==========================================================
(setq hb:*layers* '(
  ;; 名稱            顏色 線粗(0.01mm) 線型        出圖
  ("A-牆"            7   35  "Continuous" T)
  ("A-柱"            8   35  "Continuous" T)
  ("A-新砌牆"        3   35  "Continuous" T)
  ("A-拆除"          1   18  "HIDDEN"     T)
  ("A-門窗"          2   18  "Continuous" T)
  ("I-櫃體"          4   18  "Continuous" T)
  ("I-櫃體-吊櫃虛線"  4   13  "HIDDEN"     T)
  ("I-櫃體-門片線"    4   13  "HIDDEN"     T)
  ("I-家具"          3   13  "Continuous" T)
  ("I-衛浴廚具"      5   13  "Continuous" T)
  ("I-地坪"          8    9  "Continuous" T)
  ("I-天花"          6   13  "Continuous" T)
  ("I-天花-高程"      6   13  "Continuous" T)
  ("E-燈具"          1   13  "Continuous" T)
  ("E-插座"          1   13  "Continuous" T)
  ("E-開關"          1   13  "Continuous" T)
  ("E-弱電"         30   13  "Continuous" T)
  ("E-迴路線"        1    9  "HIDDEN"     T)
  ("P-給水"          5   13  "Continuous" T)
  ("P-排水"         32   13  "HIDDEN"     T)
  ("M-冷氣"        140   13  "Continuous" T)
  ("D-尺寸"          1    9  "Continuous" T)
  ("T-文字"          7   13  "Continuous" T)
  ("T-引線"          7    9  "Continuous" T)
  ("T-圖例"          7   13  "Continuous" T)
  ("Z-圖框"          8   25  "Continuous" T)
  ("Z-視埠"          8    9  "Continuous" nil)
  ("Z-參考底圖"      9    9  "Continuous" nil)
))

(defun hb:mklayer (doc spec / lay)
  (setq lay (vl-catch-all-apply 'vla-add (list (vla-get-Layers doc) (nth 0 spec))))
  (if (not (vl-catch-all-error-p lay))
    (progn
      (vla-put-Color lay (nth 1 spec))
      (vl-catch-all-apply 'vla-put-Lineweight (list lay (nth 2 spec)))
      (vl-catch-all-apply 'vla-put-Linetype (list lay (nth 3 spec)))
      (vla-put-Plottable lay (if (nth 4 spec) :vlax-true :vlax-false))))
  lay)

(defun hb:mkstyle (doc name face / st)
  (setq st (vl-catch-all-apply 'vla-add (list (vla-get-TextStyles doc) name)))
  (if (not (vl-catch-all-error-p st))
    (progn
      (vl-catch-all-apply 'vla-SetFont (list st face :vlax-false :vlax-false 136 34))
      (vla-put-Height st 0.0)
      (vla-put-Width st 1.0)))
  st)

(defun hb:mkdim (name sc)
  (setvar "DIMTXSTY" "赫柏-數字")
  (setvar "DIMTXT" 2.5)   (setvar "DIMASZ" 1.2)
  (setvar "DIMBLK" "_ARCHTICK")
  (setvar "DIMEXO" 1.5)   (setvar "DIMEXE" 1.2)  (setvar "DIMDLI" 7.0)
  (setvar "DIMGAP" 0.8)   (setvar "DIMTAD" 1)    (setvar "DIMJUST" 0)
  (setvar "DIMTIH" 0)     (setvar "DIMTOH" 0)    (setvar "DIMTMOVE" 2)
  (setvar "DIMATFIT" 3)   (setvar "DIMLUNIT" 2)  (setvar "DIMDEC" 0)
  (setvar "DIMZIN" 8)     (setvar "DIMDSEP" ".") (setvar "DIMLFAC" 1.0)
  (setvar "DIMCLRD" 256)  (setvar "DIMCLRE" 256) (setvar "DIMCLRT" 256)
  (setvar "DIMSCALE" sc)
  (if (tblsearch "DIMSTYLE" name)
    (command "_.-DIMSTYLE" "_Save" name "_Yes")
    (command "_.-DIMSTYLE" "_Save" name)))

;;; A3 圖框（附屬性：案名、圖名、比例、日期、圖號），單位：公釐（圖紙）
(defun hb:mkframe (doc / blks blk pts add-line add-text att)
  (setq blks (vla-get-Blocks doc))
  (if (tblsearch "BLOCK" "赫柏圖框_A3") (vla-item blks "赫柏圖框_A3")
    (progn
      (setq blk (vla-add blks (vlax-3d-point '(0 0 0)) "赫柏圖框_A3"))
      (defun add-line (a b / l) (setq l (vla-AddLine blk (vlax-3d-point a) (vlax-3d-point b))) (vla-put-Layer l "0") l)
      (defun add-text (s h p / tx) (setq tx (vla-AddText blk s (vlax-3d-point p) h)) (vla-put-StyleName tx "赫柏-中文") tx)
      (defun att (tag prompt def h p / a)
        (setq a (vla-AddAttribute blk h acAttributeModePreset prompt (vlax-3d-point p) tag def))
        (vla-put-StyleName a "赫柏-中文") a)
      ;; 外框 10mm 邊界
      (add-line '(10 10 0) '(410 10 0)) (add-line '(410 10 0) '(410 287 0))
      (add-line '(410 287 0) '(10 287 0)) (add-line '(10 287 0) '(10 10 0))
      ;; 右側標題欄（寬 50mm）
      (add-line '(360 10 0) '(360 287 0))
      (foreach y '(245 210 175 145 115 85 55) (add-line (list 360 y 0) (list 410 y 0)))
      (add-text "赫柏空間設計" 4.5 '(364 270 0))
      (add-text "HERFULSINS" 2.8 '(364 262 0))
      (add-text "INTERIOR DESIGN" 2.0 '(364 257 0))
      (add-text "案名" 2.0 '(363 239 0))  (att "案名" "案名" "（案名）" 3.2 '(364 227 0))
      (add-text "圖名" 2.0 '(363 204 0))  (att "圖名" "圖名" "（圖名）" 3.2 '(364 192 0))
      (add-text "比例" 2.0 '(363 169 0))  (att "比例" "比例" "1/50" 3.2 '(364 157 0))
      (add-text "日期" 2.0 '(363 139 0))  (att "日期" "日期" "2026.00.00" 3.2 '(364 127 0))
      (add-text "圖號" 2.0 '(363 109 0))  (att "圖號" "圖號" "A-01" 3.2 '(364 97 0))
      (add-text "備註" 2.0 '(363 79 0))   (att "備註" "備註" "" 2.5 '(364 68 0))
      (add-text "嘉義市西區新民路168號" 2.0 '(363 45 0))
      (add-text "0987583978" 2.0 '(363 40 0))
      (add-text "本圖版權屬赫柏空間設計所有" 1.8 '(363 15 0))
      blk)))

(defun hb:a3-canon (pc / names)
  (setq names (vl-catch-all-apply
                '(lambda () (vlax-safearray->list (vlax-variant-value (vla-GetCanonicalMediaNames pc))))))
  (if (vl-catch-all-error-p names) (setq names nil))
  (or (car (vl-remove-if-not '(lambda (n) (wcmatch (strcase n) "ISO_FULL_BLEED_A3_(420*")) names))
      (car (vl-remove-if-not '(lambda (n) (wcmatch (strcase n) "ISO_A3_(420*")) names))))

(defun hb:setup-layout (doc lay / c)
  (vl-catch-all-apply 'vla-put-ConfigName (list lay hb:*device*))
  (vl-catch-all-apply 'vla-RefreshPlotDeviceInfo (list lay))
  (if (setq c (hb:a3-canon lay)) (vl-catch-all-apply 'vla-put-CanonicalMediaName (list lay c)))
  (vl-catch-all-apply 'vla-put-PaperUnits (list lay acMillimeters))
  (vl-catch-all-apply 'vla-put-PlotRotation (list lay ac0degrees))
  (vl-catch-all-apply 'vla-put-PlotType (list lay acLayout))
  (vl-catch-all-apply 'vla-put-StandardScale (list lay acVp1_1))
  (vl-catch-all-apply 'vla-put-CenterPlot (list lay :vlax-false))
  (vl-catch-all-apply 'vla-put-PlotOrigin (list lay (vlax-make-variant (vlax-safearray-fill (vlax-make-safearray vlax-vbDouble '(0 . 1)) '(0.0 0.0)))))
  (vl-catch-all-apply 'vla-put-StyleSheet (list lay (hb:ctb)))
  (vl-catch-all-apply 'vla-put-PlotWithPlotStyles (list lay :vlax-true)))

(defun hb:make-template (/ doc lays lay ps vp f old)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (if (/= 6 (hb:yesno "會把「目前這張圖」設定成赫柏樣板：\n公分單位、圖層、字型、標註樣式（1/30、1/50、1/100）、A3 出圖頁和圖框。\n\n建議在「新的空白圖」上做。要繼續嗎？"))
    (princ)
    (progn
      (hb:begin '("CMDECHO" "CLAYER"))
      (setvar "CMDECHO" 0)
      ;; 1. 單位：公分（INSUNITS=5，匯到 3ds Max、SketchUp 比例才會對）
      (setvar "MEASUREMENT" 1) (setvar "INSUNITS" 5)
      (setvar "INSUNITSDEFSOURCE" 5) (setvar "INSUNITSDEFTARGET" 5)
      (setvar "LUNITS" 2) (setvar "LUPREC" 0) (setvar "AUNITS" 0) (setvar "AUPREC" 0)
      (setvar "LTSCALE" 1.0) (setvar "PSLTSCALE" 1) (setvar "MSLTSCALE" 1)
      (vl-catch-all-apply 'vla-load (list (vla-get-Linetypes doc) "HIDDEN" "acadiso.lin"))
      ;; 2. 圖層
      (foreach s hb:*layers* (hb:mklayer doc s))
      ;; 3. 字型
      (hb:mkstyle doc "赫柏-中文" "Microsoft JhengHei")
      (hb:mkstyle doc "赫柏-數字" "Arial")
      (setvar "TEXTSTYLE" "赫柏-中文")
      ;; 4. 標註樣式
      (hb:mkdim "赫柏_1-30" 3.0)
      (hb:mkdim "赫柏_1-100" 10.0)
      (hb:mkdim "赫柏_1-50" 5.0)
      (command "_.-DIMSTYLE" "_Restore" "赫柏_1-50")
      ;; 5. 圖框圖塊
      (hb:mkframe doc)
      ;; 6. 出圖頁：第一個配置頁改名「A3-01」，設定 A3／PDF／1:1，放圖框和 1/50 視埠
      (setq lays (hb:layouts))
      (setq lay (vla-item (vla-get-Layouts doc) (car lays)))
      (vl-catch-all-apply 'vla-put-Name (list lay "A3-01"))
      (hb:setup-layout doc lay)
      (vla-put-ActiveLayout doc lay)
      (setq ps (vla-get-PaperSpace doc))
      (vlax-for o (vla-get-Block lay)
        (if (= (vla-get-ObjectName o) "AcDbViewport") (setq old (cons o old))))
      (foreach o old (vl-catch-all-apply 'vla-delete (list o)))
      (setq f (vla-InsertBlock ps (vlax-3d-point '(0 0 0)) "赫柏圖框_A3" 1.0 1.0 1.0 0.0))
      (vla-put-Layer f "Z-圖框")
      (setq vp (vl-catch-all-apply 'vla-AddPViewport (list ps (vlax-3d-point '(185 148.5 0)) 340.0 267.0)))
      (if (not (vl-catch-all-error-p vp))
        (progn
          (vla-put-Layer vp "Z-視埠")
          (vl-catch-all-apply 'vla-put-ViewportOn (list vp :vlax-true))
          (vl-catch-all-apply 'vla-put-CustomScale (list vp (/ 10.0 50.0)))))
      ;; 其他配置頁也套 A3 設定
      (foreach n (cdr lays) (hb:setup-layout doc (vla-item (vla-get-Layouts doc) n)))
      ;; 回到模型空間、圖層設為牆
      (vla-put-ActiveSpace doc acModelSpace)
      (setvar "CLAYER" "A-牆")
      (setq hb:*vars* (vl-remove (assoc "CLAYER" hb:*vars*) hb:*vars*))
      (hb:end)
      ;; 7. 存檔
      (setq f (getfiled "把赫柏樣板存在哪裡？（建議跟赫柏工具放同一個資料夾）"
                        (strcat (hb:get "HB_TPLDIR" "") "赫柏樣板.dwg") "dwg" 1))
      (if f
        (if (vl-catch-all-error-p (vl-catch-all-apply 'vla-SaveAs (list doc f)))
          (alert "存檔失敗，請換一個位置再試。")
          (progn
            (setenv "HB_TPL" f)
            (setenv "HB_TPLDIR" (strcat (vl-filename-directory f) "\\"))
            (alert (strcat "赫柏樣板完成！\n\n" f
                           "\n\n以後新案子：按 HB →「新增案子」，會從這個樣板複製一份新圖。"))))
        (alert "樣板設定好了，但還沒存檔。請自己另存新檔。"))))
  (princ))

;;; 新增案子：從樣板複製一份，取好名字，直接打開
(defun hb:new-case (/ tpl f r)
  (setq tpl (getenv "HB_TPL"))
  (if (not (and tpl (findfile tpl)))
    (alert "還沒有赫柏樣板。\n請先開一張新的空白圖，按「建立赫柏樣板」。")
    (progn
      (setq f (getfiled "新案子要存在哪裡？請打上檔名（例如：王公館_平面圖）"
                        (hb:get "HB_CASEDIR" "") "dwg" 1))
      (if f
        (cond
          ((findfile f) (alert "這個檔名已經有了，請換一個名字。"))
          ((not (vl-file-copy tpl f)) (alert "建立失敗，請確認資料夾可以寫入。"))
          (T
           (setenv "HB_CASEDIR" (strcat (vl-filename-directory f) "\\"))
           (setq r (vl-catch-all-apply 'vla-open (list (vla-get-Documents (vlax-get-acad-object)) f)))
           (if (vl-catch-all-error-p r) (alert (strcat "已建立，請自己打開：\n" f))
             (vl-catch-all-apply 'vla-Activate (list r)))))))))

;;; ==========================================================
;;;  給 3ds Max：選取範圍 → 指定原點 → 另存乾淨的 DWG（0,0、壓平、單位保留公分）
;;; ==========================================================
(defun hb:flat-pt (p) (vlax-3d-point (list (car p) (cadr p) 0.0)))
(defun hb:flatten-dbx (dbx / n p)
  (setq n 0)
  (vlax-for e (vla-get-ModelSpace dbx)
    (setq n (1+ n))
    (vl-catch-all-apply
      '(lambda ()
         (cond
           ((vlax-property-available-p e 'Elevation T) (vla-put-Elevation e 0.0))
           ((= (vla-get-ObjectName e) "AcDbLine")
            (vla-put-StartPoint e (hb:flat-pt (vlax-get e 'StartPoint)))
            (vla-put-EndPoint e (hb:flat-pt (vlax-get e 'EndPoint))))
           ((vlax-property-available-p e 'InsertionPoint T)
            (vla-put-InsertionPoint e (hb:flat-pt (vlax-get e 'InsertionPoint))))
           ((vlax-property-available-p e 'Center T)
            (vla-put-Center e (hb:flat-pt (vlax-get e 'Center))))))))
  n)

(defun hb:to-max (/ ss bp dir out dbx n)
  (if (= (getvar "DWGTITLED") 0)
    (alert "請先把這張圖存檔，匯出的檔案會放在旁邊的「給3dsMax」資料夾。")
    (progn
      (princ "\n框選要給 3ds Max 的平面（牆、門窗、櫃體…，不要選尺寸和文字比較乾淨）")
      (if (and (setq ss (ssget))
               (setq bp (getpoint "\n點一個當原點的位置（建議點平面的左下牆角）：")))
        (progn
          (hb:begin '("CMDECHO" "INSUNITS" "FILEDIA" "EXPERT"))
          (setvar "CMDECHO" 0) (setvar "FILEDIA" 0) (setvar "EXPERT" 2)
          (if (= (getvar "INSUNITS") 0) (setvar "INSUNITS" 5))
          (setq dir (strcat (getvar "DWGPREFIX") "給3dsMax"))
          (vl-mkdir dir)
          (setq out (strcat dir "\\" (vl-filename-base (getvar "DWGNAME")) "_3dsMax.dwg"))
          (if (findfile out) (vl-file-delete out))
          (command "_.-WBLOCK" out "" "_non" bp ss "")
          (command "_.OOPS")
          (hb:end)
          (if (not (findfile out))
            (alert "匯出失敗。")
            (progn
              (setq n 0)
              (if (setq dbx (hb:dbx-open out))
                (progn
                  (setq n (hb:flatten-dbx dbx))
                  (vl-catch-all-apply 'vla-SaveAs (list dbx out))
                  (vlax-release-object dbx)))
              (alert (strcat "完成！" (itoa n) " 個物件，已移到原點 0,0、高度壓平，單位跟原圖一樣（公分）。\n\n"
                             out "\n\n3ds Max 匯入時：\n‧ 系統單位設定成「公分」\n‧ 匯入視窗的 Rescale 打勾，Incoming file units 選 Centimeters"))
              (vl-catch-all-apply 'startapp (list "explorer" (strcat "\"" dir "\"")))))))))
  (princ))

;;; ==========================================================
;;;  智能家居符號：HBSMART 一次加進圖塊庫（電_智能箱、電_AP…）
;;;  大小照你圖塊庫的習慣：圓直徑 20（公分）、圖層 0、顏色 ByBlock
;;; ==========================================================
(setq hb:*smart* '(
  ("電_智能箱"   "智能箱（弱電箱）"     rect  "智" 11.0)
  ("電_AP"       "無線基地台 AP（天花板）" circle "AP" 7.0)
  ("電_窗簾電源" "電動窗簾電源"          rect  "簾" 11.0)
  ("電_人體感應" "人體感應器"            circle "PIR" 5.5)
  ("電_攝影機"   "監視攝影機"            circle "CAM" 5.0)
  ("電_漏水感測" "漏水感測器"            circle "漏" 11.0)
))

(defun hb:mk-smart-block (blks spec / blk shape txt h o mt pts arr old)
  ;; 圖塊已存在（舊版樣式）→ 清空內容重畫；不存在 → 新建
  (if (setq blk (hb:blk blks (nth 0 spec)))
    (progn
      (vlax-for x blk (setq old (cons x old)))
      (foreach x old (vl-catch-all-apply 'vla-Delete (list x))))
    (setq blk (vla-add blks (vlax-3d-point '(0 0 0)) (nth 0 spec))))
  (setq shape (nth 2 spec) txt (nth 3 spec) h (nth 4 spec))
  (if (eq shape 'circle)
    (setq o (vla-AddCircle blk (vlax-3d-point '(0 0 0)) 10.0))
    (progn
      (setq pts (if (= txt "智") '(-15 -10 15 -10 15 10 -15 10) '(-10 -10 10 -10 10 10 -10 10)))
      (setq arr (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length pts)))))
      (vlax-safearray-fill arr pts)
      (setq o (vla-AddLightWeightPolyline blk arr))
      (vla-put-Closed o :vlax-true)))
  (vla-put-Layer o "0") (vla-put-Color o 0)
  (setq mt (vla-AddMText blk (vlax-3d-point '(0 0 0)) 0.0
             (strcat "{\\fMingLiU|b0|i0|c136|p49;" txt "}")))
  (vla-put-Height mt h)
  (vla-put-AttachmentPoint mt acAttachmentPointMiddleCenter)
  (vla-put-InsertionPoint mt (vlax-3d-point '(0 0 0)))
  (vla-put-Layer mt "0") (vla-put-Color mt 0)
  (vla-put-Comments blk (nth 1 spec))
  blk)

;;; ==========================================================
;;;  開關符號：圓圈裡寫 S（跟插座、網路面板同一套樣式：圓直徑 20）
;;;  （名稱, 說明, 形狀, 圈內文字, 字高）
;;; ==========================================================
(setq hb:*switch* '(
  ("電_單切開關"     "開關面板（單切）"       circle "S"   11.0)
  ("電_雙切開關"     "開關面板（雙切）"       circle "S2"  8.5)
  ("電_三切開關"     "開關面板（三切）"       circle "S3"  8.5)
  ("電_四切開關"     "開關面板（四切）"       circle "S4"  8.5)
  ("電_三路開關"     "三路開關（兩處控制）"   circle "3W"  8.5)
  ("電_雙切三路開關" "雙切三路開關"           circle "3W2" 6.5)
  ("電_調光開關"     "調光開關"               circle "SD"  8.5)
))

(defun hb:add-smart (blks / n)
  (setq n 0)
  ;; 開關：沒有就新增；舊版樣式（說明文字不同）就自動換成新樣式
  (foreach s hb:*switch*
    (if (or (not (hb:blk blks (car s)))
            (/= (vla-get-Comments (hb:blk blks (car s))) (nth 1 s)))
      (if (not (vl-catch-all-error-p (vl-catch-all-apply 'hb:mk-smart-block (list blks s))))
        (setq n (1+ n)))))
  (foreach s hb:*smart*
    (if (not (hb:blk blks (car s)))
      (if (not (vl-catch-all-error-p (vl-catch-all-apply 'hb:mk-smart-block (list blks s))))
        (setq n (1+ n)))))
  n)

;;; HBSWITCH：同 HBSMART，把開關符號和智能家居符號補進圖塊庫
(defun c:HBSWITCH () (c:HBSMART))

(defun c:HBSMART (/ lib doc opened dbx n)
  (setq lib (hb:lib) doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (if (not (and (/= lib "") (findfile lib)))
    (progn (alert "請先指定圖塊庫（HB →「指定圖塊庫」），再執行一次 HBSMART。") (princ))
    (progn
      (vlax-for d (vla-get-Documents (vlax-get-acad-object))
        (if (= (strcase (vla-get-FullName d)) (strcase lib)) (setq opened d)))
      (cond
        ((and opened (equal opened doc))
         (setq n (hb:add-smart (vla-get-Blocks doc)))
         (vla-Save doc)
         (alert (strcat "加入 " (itoa n) " 個標準符號（開關、智能家居），圖塊庫已存檔。")))
        (opened (alert "圖塊庫目前在 CAD 裡開著。請切到那張圖再執行 HBSMART，或先把它關掉。"))
        ((setq dbx (hb:dbx-open lib))
         (setq n (hb:add-smart (vla-get-Blocks dbx)))
         (if (> n 0)
           (if (vl-catch-all-error-p (vl-catch-all-apply 'vla-SaveAs (list dbx lib)))
             (alert "圖塊庫存檔失敗（可能是唯讀），沒有加入。")
             (alert (strcat "加入 " (itoa n) " 個標準符號（開關、智能家居）到圖塊庫。\n按 HB →「放水電符號」就能用。")))
           (alert "這些符號圖塊庫裡都已經有了。"))
         (vlax-release-object dbx))
        (T (alert "打不開圖塊庫。")))))
  (princ))

;;; ==========================================================
;;;  智能型標記：符號右上加實心三角（黑白列印也分得出來）
;;;  「轉成智能型」：框選符號 → 換成「原名_智能」，位置、角度、比例、圖層都不變
;;;  「轉回一般型」：換回原本的符號
;;; ==========================================================
(defun hb:smart-base (n) (if (wcmatch n "*_智能") (substr n 1 (- (strlen n) (strlen "_智能"))) n))

(defun hb:bbox (doc name / tmp mn mx r)
  (setq tmp (vla-InsertBlock (vla-get-ModelSpace doc) (vlax-3d-point '(0 0 0)) name 1.0 1.0 1.0 0.0))
  (setq r (vl-catch-all-apply 'vla-GetBoundingBox (list tmp 'mn 'mx)))
  (vla-delete tmp)
  (if (vl-catch-all-error-p r) nil
    (list (vlax-safearray->list mn) (vlax-safearray->list mx))))

;;; 三角放在符號外框的右上角「裡面」（圓形符號右上角本來就是空白），不會壓到旁邊的數字
(defun hb:smart-tri (blk bb / xmax ymax w s sol)
  (setq xmax (car (cadr bb)) ymax (cadr (cadr bb))
        w (min (- xmax (car (car bb))) (- ymax (cadr (car bb))))
        s (* 0.3 w))
  (setq sol (vla-AddSolid blk
              (vlax-3d-point (list xmax ymax 0))
              (vlax-3d-point (list (- xmax s) ymax 0))
              (vlax-3d-point (list xmax (- ymax s) 0))
              (vlax-3d-point (list xmax (- ymax s) 0))))
  (vla-put-Layer sol "0") (vla-put-Color sol 0)
  sol)

;;; 建立「name_智能」圖塊（裡面＝原符號＋右上實心三角）；已經有的話把三角更新成新位置
(defun hb:smart-def (doc name / sname blks bb blk ins desc old)
  (setq sname (strcat name "_智能") blks (vla-get-Blocks doc))
  (if (setq bb (hb:bbox doc name))
    (progn
      (if (tblsearch "BLOCK" sname)
        (progn
          (setq blk (vla-item blks sname))
          (vlax-for e blk (if (= (vla-get-ObjectName e) "AcDbSolid") (setq old (cons e old))))
          (foreach e old (vla-delete e))
          (hb:smart-tri blk bb))
        (progn
          (setq blk (vla-add blks (vlax-3d-point '(0 0 0)) sname))
          (setq ins (vla-InsertBlock blk (vlax-3d-point '(0 0 0)) name 1.0 1.0 1.0 0.0))
          (vla-put-Layer ins "0") (vla-put-Color ins 0)
          (hb:smart-tri blk bb)
          (setq desc (vla-get-Comments (vla-item blks name)))
          (vla-put-Comments blk (strcat (if (/= desc "") desc (hb:smart-base name)) "（智能）"))))
      sname)))

;;; 把這張圖裡所有智能型符號的三角，更新成新的位置和大小
(defun c:HBSMARTFIX (/ doc n)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)) n 0)
  (vla-StartUndoMark doc)
  (vlax-for b (vla-get-Blocks doc)
    (if (and (wcmatch (vla-get-Name b) "*_智能") (tblsearch "BLOCK" (hb:smart-base (vla-get-Name b))))
      (progn (hb:smart-def doc (hb:smart-base (vla-get-Name b))) (setq n (1+ n)))))
  (vla-EndUndoMark doc)
  (vla-Regen doc acAllViewports)
  (hb:say (strcat "已更新 " (itoa n) " 種智能型符號的三角位置。"))
  (princ))

(defun hb:swap-ref (doc ref newname / sp nr)
  (setq sp (vla-ObjectIDToObject doc (vla-get-OwnerID ref)))
  (setq nr (vla-InsertBlock sp (vla-get-InsertionPoint ref) newname
             (vla-get-XScaleFactor ref) (vla-get-YScaleFactor ref) (vla-get-ZScaleFactor ref)
             (vla-get-Rotation ref)))
  (vla-put-Layer nr (vla-get-Layer ref))
  (vl-catch-all-apply 'vla-put-Color (list nr (vla-get-Color ref)))
  (vla-delete ref)
  nr)

(defun hb:smart-convert (to-smart / doc ss i ref nm target n)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)) n 0)
  (princ (if to-smart "\n框選要改成「智能型」的插座、開關…" "\n框選要改回「一般型」的符號…"))
  (if (setq ss (ssget '((0 . "INSERT"))))
    (progn
      (vla-StartUndoMark doc)
      (setq i 0)
      (repeat (sslength ss)
        (setq ref (vlax-ename->vla-object (ssname ss i)) i (1+ i))
        (setq nm (vl-catch-all-apply 'vla-get-EffectiveName (list ref)))
        (if (vl-catch-all-error-p nm) (setq nm (vla-get-Name ref)))
        (cond
          ((wcmatch nm "`**,*|*") nil)
          ((and to-smart (not (wcmatch nm "*_智能")))
           (if (setq target (hb:smart-def doc nm)) (progn (hb:swap-ref doc ref target) (setq n (1+ n)))))
          ((and (not to-smart) (wcmatch nm "*_智能") (tblsearch "BLOCK" (hb:smart-base nm)))
           (hb:swap-ref doc ref (hb:smart-base nm)) (setq n (1+ n)))))
      (vla-EndUndoMark doc)
      (vla-Regen doc acAllViewports)
      (hb:say (strcat (if to-smart "改成智能型：" "改回一般型：") (itoa n) " 個"
                      (if to-smart "（圖例表請重做一次，智能型會分開統計）" "")))))
  (princ))

;;; ==========================================================
;;;  拉伸軌道燈：點起點、終點，燈具自動等距排列；之後可再拉長／縮短
;;;  軌道＋燈具自動成組，放在 E-燈具 圖層（不加文字）
;;;  單位公分。圖例＋數量表會另外統計軌道燈總長度與盞數。
;;;  也可直接打指令：HBTRK 畫、HBTRKS 拉伸
;;; ==========================================================
(setq hb:*trk-layer* "E-燈具")
(if (not hb:*trk-w*)  (setq hb:*trk-w*  4.0))    ; 軌道寬
(if (not hb:*trk-d*)  (setq hb:*trk-d*  12.0))   ; 燈具直徑
(if (not hb:*trk-sp*) (setq hb:*trk-sp* 60.0))   ; 自動排列間距

(defun hb:trk-doc () (vla-get-ActiveDocument (vlax-get-acad-object)))
(defun hb:trk-2d (p) (list (car p) (cadr p)))
(defun hb:trk-mid (a b) (mapcar '(lambda (x y) (/ (+ x y) 2.0)) a b))
(defun hb:trk-auto (len) (max 1 (fix (+ (/ len hb:*trk-sp*) 0.5))))

(defun hb:trk-prep ()
  (if (not (tblsearch "LAYER" hb:*trk-layer*))
    (hb:mklayer (hb:trk-doc) (assoc hb:*trk-layer* hb:*layers*)))
  (if (not (tblsearch "APPID" "HB_TRACK")) (regapp "HB_TRACK")))

;;; 軌道物件的資料：回傳 (p1 p2 盞數 軌寬 燈徑)，不是軌道燈就回傳 nil
(defun hb:trk-info (en / ed xd vs)
  (setq ed (entget en '("HB_TRACK")))
  (if (and (= (cdr (assoc 0 ed)) "LWPOLYLINE") (assoc -3 ed))
    (progn
      (setq xd (cdr (cadr (assoc -3 ed))))
      (setq vs (mapcar 'cdr (vl-remove-if-not '(lambda (x) (= (car x) 10)) ed)))
      (if (= (length vs) 4)
        (list (hb:trk-mid (nth 0 vs) (nth 3 vs)) (hb:trk-mid (nth 1 vs) (nth 2 vs))
              (cdr (assoc 1070 xd)) (cdr (assoc 1040 xd)) (cdr (nth 3 xd)))))))

;;; 畫一組軌道燈，回傳物件清單
(defun hb:trk-draw (p1 p2 n w d / ang len prp a b c e out i pc)
  (setq p1 (hb:trk-2d p1) p2 (hb:trk-2d p2)
        ang (angle p1 p2) len (distance p1 p2) prp (+ ang (/ pi 2.0)))
  (setq a (polar p1 prp (/ w 2.0))  b (polar p2 prp (/ w 2.0))
        c (polar p2 prp (/ w -2.0)) e (polar p1 prp (/ w -2.0)))
  (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") (cons 8 hb:*trk-layer*)
                 '(100 . "AcDbPolyline") '(90 . 4) '(70 . 1)
                 (cons 10 a) (cons 10 b) (cons 10 c) (cons 10 e)
                 (list -3 (list "HB_TRACK" '(1000 . "TRACK")
                                (cons 1070 n) (cons 1040 w) (cons 1040 d)))))
  (setq out (list (entlast)) i 0)
  (repeat n
    (setq pc (polar p1 ang (* (/ len n) (+ i 0.5))))
    (entmake (list '(0 . "CIRCLE") (cons 8 hb:*trk-layer*) (cons 10 pc) (cons 40 (/ d 2.0))))
    (setq out (cons (entlast) out) i (1+ i)))
  out)

(defun hb:trk-group (enames / grps grp arr)
  (setq grps (vla-get-Groups (hb:trk-doc)))
  (setq grp (vl-catch-all-apply 'vla-add (list grps "*")))
  (if (vl-catch-all-error-p grp)
    (setq grp (vla-add grps (strcat "HB_TRK_" (cdr (assoc 5 (entget (car enames))))))))
  (setq arr (vlax-make-safearray vlax-vbObject (cons 0 (1- (length enames)))))
  (vlax-safearray-fill arr (mapcar 'vlax-ename->vla-object enames))
  (vla-AppendItems grp arr)
  grp)

(defun hb:trk-findgroup (obj / res h)
  (setq h (vla-get-Handle obj))
  (vlax-for g (vla-get-Groups (hb:trk-doc))
    (if (not res) (vlax-for o g (if (= (vla-get-Handle o) h) (setq res g)))))
  res)

(defun hb:trk-settings (/ ans)
  (initget 6) (if (setq ans (getreal (strcat "\n軌道寬 <" (rtos hb:*trk-w* 2 1) ">："))) (setq hb:*trk-w* ans))
  (initget 6) (if (setq ans (getreal (strcat "\n燈具直徑 <" (rtos hb:*trk-d* 2 1) ">："))) (setq hb:*trk-d* ans))
  (initget 6) (if (setq ans (getreal (strcat "\n自動排列間距 <" (rtos hb:*trk-sp* 2 1) ">："))) (setq hb:*trk-sp* ans)))

;;; 畫軌道燈
(defun hb:trk-new (/ p1 p2 n auto doc)
  (setq doc (hb:trk-doc))
  (hb:begin '("CMDECHO"))
  (hb:trk-prep)
  (initget "S")
  (setq p1 (getpoint (strcat "\n軌道燈起點 [設定(S)] <軌寬" (rtos hb:*trk-w* 2 0) " 燈徑" (rtos hb:*trk-d* 2 0)
                             " 間距" (rtos hb:*trk-sp* 2 0) ">：")))
  (while (= p1 "S")
    (hb:trk-settings)
    (initget "S")
    (setq p1 (getpoint "\n軌道燈起點 [設定(S)]：")))
  (if (and p1 (setq p2 (getpoint p1 "\n軌道燈終點：")))
    (progn
      (setq auto (hb:trk-auto (distance (hb:trk-2d p1) (hb:trk-2d p2))))
      (initget 6)
      (setq n (getint (strcat "\n燈具數量 <" (itoa auto) ">：")))
      (if (not n) (setq n auto))
      (vla-StartUndoMark doc)
      (hb:trk-group (hb:trk-draw p1 p2 n hb:*trk-w* hb:*trk-d*))
      (vla-EndUndoMark doc)
      (hb:say (strcat "軌道燈 L=" (rtos (distance (hb:trk-2d p1) (hb:trk-2d p2)) 2 0) "，" (itoa n) " 盞。"))))
  (hb:end)
  (princ))

;;; 拉伸軌道燈：點靠近要動的那一端 → 點新位置
(defun hb:trk-stretch (/ doc sel en pp obj grp trk info members p1 p2 fxp newp len n ans)
  (setq doc (hb:trk-doc))
  (hb:begin '("CMDECHO"))
  (hb:trk-prep)
  (if (setq sel (entsel "\n點選要拉伸的軌道燈（點靠近要移動的那一端）："))
    (progn
      (setq en (car sel) pp (hb:trk-2d (cadr sel)) obj (vlax-ename->vla-object en))
      (if (setq grp (hb:trk-findgroup obj))
        (vlax-for o grp
          (setq members (cons (vlax-vla-object->ename o) members))
          (if (hb:trk-info (vlax-vla-object->ename o)) (setq trk (vlax-vla-object->ename o))))
        (if (hb:trk-info en) (setq trk en members (list en))))
      (if (not trk)
        (alert "這個不是赫柏軌道燈。\n請點用「軌道燈」按鈕畫出來的軌道燈。")
        (progn
          (setq info (hb:trk-info trk) p1 (nth 0 info) p2 (nth 1 info) n (nth 2 info))
          (setq fxp (if (< (distance pp p1) (distance pp p2)) p2 p1))
          (if (setq newp (getpoint fxp "\n新的端點位置："))
            (progn
              (setq newp (hb:trk-2d newp) len (distance fxp newp))
              (initget 6 "A")
              (setq ans (getint (strcat "\n燈具數量 [自動(A)=" (itoa (hb:trk-auto len)) "] <維持 " (itoa n) ">：")))
              (cond ((= ans "A") (setq n (hb:trk-auto len)))
                    ((numberp ans) (setq n ans)))
              (vla-StartUndoMark doc)
              (if grp (vla-Delete grp))
              (foreach m members (entdel m))
              (hb:trk-group (if (equal fxp p2 1e-6)
                              (hb:trk-draw newp p2 n (nth 3 info) (nth 4 info))
                              (hb:trk-draw p1 newp n (nth 3 info) (nth 4 info))))
              (vla-EndUndoMark doc)
              (hb:say (strcat "已拉伸為 L=" (rtos len 2 0) "，" (itoa n) " 盞。"))))))))
  (hb:end)
  (princ))

(defun c:HBTRK () (hb:trk-new))
(defun c:HBTRKS () (hb:trk-stretch))

;;; ==========================================================
;;;  門片開門線：點門片框「內部」一下，自動畫開門虛線（尖端＝鉸鏈側）
;;;  左開／右開／對開（菱形）／上掀／下掀；門框沒封閉時可用兩角框選
;;;  可以連續點很多扇，按 Enter 結束；整次用一次 U 就能全部退回
;;;  放在 I-櫃體-門片線 圖層（HIDDEN）。也可直接打指令：HBDOOR
;;; ==========================================================
(setq hb:*door-layer* "I-櫃體-門片線")
(if (not hb:*door-mode*) (setq hb:*door-mode* "P"))

(defun hb:door-name (m)
  (cdr (assoc m '(("L" . "左開") ("R" . "右開") ("P" . "對開") ("U" . "上掀") ("D" . "下掀")))))

(defun hb:door-prep (/ doc)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (if (not (tblsearch "LTYPE" "HIDDEN"))
    (vl-catch-all-apply 'vla-load (list (vla-get-Linetypes doc) "HIDDEN" "acadiso.lin")))
  (if (not (tblsearch "LAYER" hb:*door-layer*))
    (hb:mklayer doc (assoc hb:*door-layer* hb:*layers*))))

;;; 三點聚合線（線型連續產生，虛線在尖端不會斷掉）
(defun hb:door-pl (pts)
  (entmake (append (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") (cons 8 hb:*door-layer*)
                         '(100 . "AcDbPolyline") (cons 90 (length pts)) '(70 . 128))
                   (mapcar '(lambda (p) (list 10 (car p) (cadr p))) pts))))

;;; 點門片內部 → 找封閉範圍 → (x1 y1 x2 y2)
(defun hb:door-box-at (pt / e lst)
  (setq e (vl-catch-all-apply 'bpoly (list pt)))
  (if (and e (not (vl-catch-all-error-p e)) (= (type e) 'ENAME))
    (progn
      (setq lst (mapcar 'cdr (vl-remove-if-not '(lambda (x) (= (car x) 10)) (entget e))))
      (entdel e)
      (if lst
        (list (apply 'min (mapcar 'car lst)) (apply 'min (mapcar 'cadr lst))
              (apply 'max (mapcar 'car lst)) (apply 'max (mapcar 'cadr lst)))))))

(defun hb:door-box-2pt (p1 p2)
  (list (min (car p1) (car p2)) (min (cadr p1) (cadr p2))
        (max (car p1) (car p2)) (max (cadr p1) (cadr p2))))

(defun hb:door-draw (b / x1 y1 x2 y2 xm ym)
  (setq x1 (nth 0 b) y1 (nth 1 b) x2 (nth 2 b) y2 (nth 3 b)
        xm (/ (+ x1 x2) 2.0) ym (/ (+ y1 y2) 2.0))
  (if (or (< (- x2 x1) 1e-6) (< (- y2 y1) 1e-6))
    (hb:say "範圍太小，略過。")
    (cond
      ((= hb:*door-mode* "L") (hb:door-pl (list (list x2 y2) (list x1 ym) (list x2 y1))))
      ((= hb:*door-mode* "R") (hb:door-pl (list (list x1 y2) (list x2 ym) (list x1 y1))))
      ((= hb:*door-mode* "U") (hb:door-pl (list (list x1 y1) (list xm y2) (list x2 y1))))
      ((= hb:*door-mode* "D") (hb:door-pl (list (list x1 y2) (list xm y1) (list x2 y2))))
      ((= hb:*door-mode* "P")
        (hb:door-pl (list (list xm y2) (list x1 ym) (list xm y1)))
        (hb:door-pl (list (list xm y2) (list x2 ym) (list xm y1)))))))

;;; mode：L／R／P／U／D（nil＝沿用上次）
(defun hb:door (mode / doc pt p1 p2 box done n)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)) n 0)
  (hb:begin '("CMDECHO"))
  (if mode (setq hb:*door-mode* mode))
  (if (= (getvar "WORLDUCS") 0)
    (hb:say "提醒：目前不是世界座標，線可能會偏。可先輸入 UCS 再按 Enter 回到世界座標。"))
  (hb:door-prep)
  (vla-StartUndoMark doc)
  (setq hb:*undo-open* T)
  (while (not done)
    (initget "L R P U D C")
    (setq pt (getpoint (strcat "\n點門片框內部（目前：" (hb:door-name hb:*door-mode*)
                               "）或 [左開(L)/右開(R)/對開(P)/上掀(U)/下掀(D)/兩角框選(C)] <結束>：")))
    (cond
      ((null pt) (setq done T))
      ((= pt "C")
        (setq p1 (getpoint "\n門片第一個角點："))
        (if p1 (setq p2 (getcorner p1 "\n對角點：")))
        (if (and p1 p2) (progn (hb:door-draw (hb:door-box-2pt p1 p2)) (setq n (1+ n)))))
      ((= (type pt) 'STR)
        (setq hb:*door-mode* pt)
        (hb:say (strcat "已切換為：" (hb:door-name pt))))
      (T
        (if (setq box (hb:door-box-at pt))
          (progn (hb:door-draw box) (setq n (1+ n)))
          (hb:say "找不到封閉範圍：請確認門片四邊有封閉、整扇門都在畫面內；或輸入 C 用兩角框選。")))))
  (vla-EndUndoMark doc)
  (setq hb:*undo-open* nil)
  (if (> n 0) (hb:say (strcat "門片線完成 " (itoa n) " 扇。")))
  (hb:end)
  (princ))

(defun c:HBDOOR () (hb:door nil))

;;; ==========================================================
;;;  面板（DCL 在執行時自動產生，不用另外放檔案）
;;; ==========================================================
(defun hb:write-dcl (/ fn f)
  (setq fn (strcat (getvar "TEMPPREFIX") "HB_tools.dcl"))
  (setq f (open fn "w"))
  (foreach s
    '("hb_main : dialog { label = \"赫柏工具  HERFULSINS（第 13 版）\";"
      " : text { label = \"點按鈕就好，不用記指令。下次只要輸入 HB 打開這裡。\"; }"
      " : spacer { height = 0.5; }"
      " : boxed_column { label = \"出 PDF（A3 橫式、1:1、存到 PDF_OUTPUT）\";"
      "   : button { key = \"pdf1\"; label = \"出 PDF：這張圖\"; height = 2.2; }"
      "   : button { key = \"pdfall\"; label = \"出 PDF：整個資料夾\"; height = 2.2; }"
      " }"
      " : boxed_column { label = \"水電\";"
      "   : button { key = \"sym\"; label = \"放水電符號\"; height = 2.2; }"
      "   : row { : button { key = \"legend\"; label = \"圖例＋數量表\"; height = 2.2; }"
      "           : button { key = \"hgt\"; label = \"加安裝高度\"; height = 2.2; } }"
      "   : row { : button { key = \"tosmart\"; label = \"轉成智能型（▲）\"; }"
      "           : button { key = \"tonormal\"; label = \"轉回一般型\"; } }"
      "   : row { : button { key = \"trk\"; label = \"軌道燈\"; }"
      "           : button { key = \"trks\"; label = \"拉伸軌道燈\"; } }"
      " }"
      " : boxed_column { label = \"櫃體門片開門線（按完到圖上點門片框內部，可連續點）\";"
      "   : row { : button { key = \"dL\"; label = \"左開\"; }"
      "           : button { key = \"dR\"; label = \"右開\"; }"
      "           : button { key = \"dP\"; label = \"對開\"; }"
      "           : button { key = \"dU\"; label = \"上掀\"; }"
      "           : button { key = \"dD\"; label = \"下掀\"; } }"
      " }"
      " : boxed_column { label = \"樣板與 3D\";"
      "   : button { key = \"newcase\"; label = \"新增案子（從赫柏樣板開新圖）\"; height = 2.2; }"
      "   : row { : button { key = \"tomax\"; label = \"給 3ds Max\"; }"
      "           : button { key = \"mktpl\"; label = \"建立赫柏樣板\"; } }"
      " }"
      " : boxed_column { label = \"設定\";"
      "   : text { key = \"libtxt\"; width = 52; }"
      "   : row { : button { key = \"setlib\"; label = \"指定圖塊庫\"; }"
      "           : button { key = \"setctb\"; label = \"出圖樣式表\"; } }"
      " }"
      " : spacer { height = 0.5; }"
      " : button { key = \"cancel\"; label = \"關閉\"; is_cancel = true; fixed_width = true; alignment = centered; width = 14; }"
      "}"
      "hb_leg : dialog { label = \"圖例＋數量表\";"
      " : text { label = \"勾選要放進圖例表的符號（可複選；這一頁有用到的已經勾好，後面是數量）：\"; }"
      " : list_box { key = \"lst\"; width = 64; height = 22; multiple_select = true; }"
      " : row { : button { key = \"all\"; label = \"全選\"; width = 12; }"
      "         : button { key = \"none\"; label = \"全部取消\"; width = 12; }"
      "         : button { key = \"accept\"; label = \"確定\"; is_default = true; width = 12; }"
      "         : button { key = \"cancel\"; label = \"取消\"; is_cancel = true; width = 12; } }"
      "}"
      "hb_pick : dialog { label = \"一起列入數量表\";"
      " : text { label = \"這些圖塊不在圖塊庫裡。勾選要一起列入表格的（可複選）。不知道是哪個，點一下再按「在圖上看是哪個」：\"; }"
      " : list_box { key = \"lst\"; width = 60; height = 18; multiple_select = true; }"
      " : row { : button { key = \"all\"; label = \"全選\"; width = 12; }"
      "         : button { key = \"show\"; label = \"在圖上看是哪個\"; width = 18; }"
      "         : button { key = \"accept\"; label = \"確定\"; is_default = true; width = 12; }"
      "         : button { key = \"cancel\"; label = \"都不要\"; is_cancel = true; width = 12; } }"
      "}"
      "hb_sym : dialog { label = \"放水電符號\";"
      " : text { label = \"選一個符號，按「放置」，然後在圖上點位置（可以連續放）。\"; }"
      " : list_box { key = \"lst\"; width = 52; height = 20; }"
      " : row { : button { key = \"accept\"; label = \"放置\"; is_default = true; width = 14; }"
      "         : button { key = \"cancel\"; label = \"取消\"; is_cancel = true; width = 14; } }"
      "}")
    (write-line s f))
  (close f)
  fn)

(defun hb:sym-dialog (/ blocks id choice idx)
  (if (hb:need-lib)
    (progn
      (hb:lib-tidy)
      (setq blocks (hb:lib-blocks))
      ;; 圖塊庫沒有開關符號 → 問要不要自動補上
      ;; 圖塊庫沒有開關符號，或還是舊樣式 → 自動補上／更新（不用再問）
      (if (and blocks
               (vl-some '(lambda (s / b) (setq b (assoc (car s) blocks)) (or (null b) (/= (cdr b) (nth 1 s)))) hb:*switch*))
        (progn (c:HBSMART) (setq blocks (hb:lib-blocks))))
      (if (null blocks)
        (alert "圖塊庫裡沒有找到圖塊。\n請確認選的是放符號的 DWG（符號要做成圖塊）。")
        (progn
          (setq id (load_dialog (hb:write-dcl)))
          (if (new_dialog "hb_sym" id)
            (progn
              (start_list "lst")
              (foreach b blocks
                (add_list (hb:label b)))
              (end_list)
              (set_tile "lst" (if hb:*last-sym* hb:*last-sym* "0"))
              (action_tile "lst" "(setq idx $value) (if (= $reason 4) (done_dialog 1))")
              (action_tile "accept" "(setq idx (get_tile \"lst\")) (done_dialog 1)")
              (setq choice (start_dialog))))
          (unload_dialog id)
          (if (and (= choice 1) idx (/= idx ""))
            (progn
              (setq hb:*last-sym* idx)
              (hb:place (car (nth (atoi idx) blocks))))))))))

(defun hb:set-ctb (/ s)
  (setq s (getstring T (strcat "\n出圖樣式表名稱 <" (hb:ctb) ">：")))
  (if (/= s "") (progn (setenv "HB_CTB" s) (hb:say (strcat "出圖樣式表：" s))))
  (princ))

(defun c:HB (/ id act)
  (setq act 99)
  (while (> act 1)
    (setq id (load_dialog (hb:write-dcl)))
    (if (not (new_dialog "hb_main" id)) (progn (setq act 0) (alert "面板開不起來。"))
      (progn
        (set_tile "libtxt" (strcat "圖塊庫：" (if (/= (hb:lib) "") (vl-filename-base (hb:lib)) "（尚未指定）")
                                   "　｜　樣式表：" (hb:ctb)))
        (action_tile "pdf1" "(done_dialog 2)")
        (action_tile "pdfall" "(done_dialog 3)")
        (action_tile "sym" "(done_dialog 4)")
        (action_tile "legend" "(done_dialog 5)")
        (action_tile "setlib" "(done_dialog 6)")
        (action_tile "setctb" "(done_dialog 7)")
        (action_tile "newcase" "(done_dialog 8)")
        (action_tile "tomax" "(done_dialog 9)")
        (action_tile "mktpl" "(done_dialog 10)")
        (action_tile "tosmart" "(done_dialog 11)")
        (action_tile "tonormal" "(done_dialog 12)")
        (action_tile "trk" "(done_dialog 13)")
        (action_tile "trks" "(done_dialog 14)")
        (action_tile "dL" "(done_dialog 15)")
        (action_tile "dR" "(done_dialog 16)")
        (action_tile "dP" "(done_dialog 17)")
        (action_tile "dU" "(done_dialog 18)")
        (action_tile "dD" "(done_dialog 19)")
        (action_tile "hgt" "(done_dialog 20)")
        (setq act (start_dialog))))
    (unload_dialog id)
    (cond
      ((= act 2) (hb:pdf-this) (setq act 0))
      ((= act 3) (hb:pdf-folder) (setq act 0))
      ((= act 4) (hb:sym-dialog) (setq act 0))
      ((= act 5) (hb:legend) (setq act 0))
      ((= act 6) (hb:set-lib))          ; 設定完回到面板
      ((= act 7) (hb:set-ctb))
      ((= act 8) (hb:new-case) (setq act 0))
      ((= act 9) (hb:to-max) (setq act 0))
      ((= act 10) (hb:make-template) (setq act 0))
      ((= act 11) (hb:smart-convert T) (setq act 0))
      ((= act 12) (hb:smart-convert nil) (setq act 0))
      ((= act 13) (hb:trk-new) (setq act 0))
      ((= act 14) (hb:trk-stretch) (setq act 0))
      ((= act 15) (hb:door "L") (setq act 0))
      ((= act 16) (hb:door "R") (setq act 0))
      ((= act 17) (hb:door "P") (setq act 0))
      ((= act 18) (hb:door "U") (setq act 0))
      ((= act 19) (hb:door "D") (setq act 0))
      ((= act 20) (hb:h-batch) (setq act 0))))
  (princ))

(princ "\n【赫柏】赫柏工具（第 13 版）已載入。輸入 HB 打開面板。（新增：開關符號、安裝高度、填入現有圖例表）")
(princ)
