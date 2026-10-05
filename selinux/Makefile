########################################
# Hazkey CommunityのSELinuxポリシーモジュールのMakefile
#
# CMakeを使わずに、ポリシーモジュールだけをビルドする場合に使う
# 通常は、CMakeで-DENABLE_SELINUX=ONを指定してビルドする (README.mdを参照)
#
# このMakefileは、hazkey_community.fc (/usr、/usr/local、/opt/hazkey-community、~/.localの規則) を使う
# これ以外の場所へインストールした場合は、CMakeでビルドするか、semanage fcontextで規則を追加する
#
# 使い方:
#   make              # ポリシーパッケージ (.pp) のビルド
#   sudo make install # モジュールの読み込みとラベルの付け直し
#   sudo make unload  # モジュールの削除
#   make clean        # ビルド成果物の削除
########################################

.PHONY: all install load unload check clean help interface FORCE

########################################
# 設定
########################################

POLICY_NAME = hazkey_community

CHECKMODULE = /usr/bin/checkmodule
SEMODULE_PACKAGE = /usr/bin/semodule_package
SEMODULE = /usr/sbin/semodule
RESTORECON = /usr/sbin/restorecon

# ポリシーソースの型名の系統
#
# hazkey_community.teは、Fedora / RHEL / openSUSEのポリシーの型名 (config_home_t等) で書かれている
# Debian 13とUbuntu 26.04はupstream Reference Policyの型名 (xdg_config_t等) を使うため、
# hazkey_community_refpolicy.awkで型名を置き換えてからビルドする
#
#   auto      ビルド環境のポリシーから判定する (xdg_config_tがあればrefpolicy、それ以外はredhat)
#   redhat    Fedora / RHEL / openSUSE向け
#   refpolicy Debian / Ubuntu向け
#
# 別のディストリビューション向けに、ビルド環境と異なる系統の.ppを作る場合は明示的に指定する
#   make FLAVOR=refpolicy
FLAVOR ?= auto

# 判定には、ビルドを実行する環境の/etc/selinux配下を使う
# パッケージ作成用のコンテナ (/etc/selinuxが無い環境) やクロスビルドでは、判定できないためredhatになる
# このような環境では、FLAVORを明示的に指定する
ifeq ($(FLAVOR),auto)
ifneq ($(shell grep -l -s xdg_config_t /etc/selinux/*/contexts/files/file_contexts.homedirs 2>/dev/null),)
EFFECTIVE_FLAVOR = refpolicy
else
EFFECTIVE_FLAVOR = redhat
ifeq ($(wildcard /etc/selinux/*/contexts/files/file_contexts.homedirs),)
$(warning SELinux policy not found under /etc/selinux: assuming FLAVOR=redhat (specify FLAVOR=refpolicy for Debian / Ubuntu))
endif
endif
else
EFFECTIVE_FLAVOR = $(FLAVOR)
endif

ifeq ($(filter $(EFFECTIVE_FLAVOR),redhat refpolicy),)
$(error FLAVOR must be auto, redhat or refpolicy: $(FLAVOR))
endif

# ラベルを付け直すインストール先 (存在しないものは無視する)
RELABEL_PATHS = \
	/usr/lib/hazkey-community /usr/lib64/hazkey-community \
	/usr/lib/x86_64-linux-gnu/hazkey-community /usr/lib/aarch64-linux-gnu/hazkey-community \
	/usr/lib/fcitx5/fcitx5-hazkey-community.so /usr/lib64/fcitx5/fcitx5-hazkey-community.so \
	/usr/lib/x86_64-linux-gnu/fcitx5/fcitx5-hazkey-community.so /usr/lib/aarch64-linux-gnu/fcitx5/fcitx5-hazkey-community.so \
	/usr/libexec/ibus-hazkey-community /usr/share/hazkey-community \
	/usr/local/lib/hazkey-community /usr/local/lib64/hazkey-community \
	/usr/local/lib/fcitx5/fcitx5-hazkey-community.so /usr/local/lib64/fcitx5/fcitx5-hazkey-community.so \
	/usr/local/lib/x86_64-linux-gnu/hazkey-community /usr/local/lib/aarch64-linux-gnu/hazkey-community \
	/usr/local/lib/x86_64-linux-gnu/fcitx5/fcitx5-hazkey-community.so /usr/local/lib/aarch64-linux-gnu/fcitx5/fcitx5-hazkey-community.so \
	/usr/local/libexec/ibus-hazkey-community /usr/local/share/hazkey-community \
	/opt/hazkey-community

# 既存ユーザのHazkey Community専用ディレクトリと、ホームディレクトリへのインストール先
RELABEL_HOME_GLOBS = \
	/home/*/.config/hazkey-community /home/*/.local/share/hazkey-community \
	/home/*/.local/state/hazkey-community /home/*/.cache/hazkey-community \
	/home/*/.local/lib/hazkey-community /home/*/.local/lib64/hazkey-community \
	/home/*/.local/lib/fcitx5/fcitx5-hazkey-community.so \
	/home/*/.local/lib64/fcitx5/fcitx5-hazkey-community.so \
	/home/*/.local/libexec/ibus-hazkey-community \
	/root/.config/hazkey-community /root/.local/share/hazkey-community \
	/root/.local/state/hazkey-community /root/.cache/hazkey-community \
	/root/.local/lib/hazkey-community /root/.local/lib64/hazkey-community \
	/root/.local/lib/fcitx5/fcitx5-hazkey-community.so \
	/root/.local/lib64/fcitx5/fcitx5-hazkey-community.so \
	/root/.local/libexec/ibus-hazkey-community

ifeq ($(wildcard $(CHECKMODULE)),)
$(error checkmodule not found. Install selinux-policy-devel (openSUSE) or checkpolicy (RHEL/Fedora))
endif

ifeq ($(wildcard $(SEMODULE_PACKAGE)),)
$(error semodule_package not found. Install policycoreutils-devel or selinux-policy-devel)
endif

########################################
# ビルド
########################################

all: $(POLICY_NAME).pp

# .teを.modへコンパイルする
# refpolicyの場合は、型名を置き換えた.teを.checkmoduleの作業用ディレクトリへ生成する
# checkmoduleは、モジュール名と出力ファイル名の一致を要求するため、ファイル名はhazkey_community.teのままにする
ifeq ($(EFFECTIVE_FLAVOR),refpolicy)
BUILD_TE = .build/$(POLICY_NAME).te

$(BUILD_TE): $(POLICY_NAME).te $(POLICY_NAME)_refpolicy.awk
	@echo "Converting type names for the refpolicy flavor: $< -> $@"
	@mkdir -p .build
	awk -f $(POLICY_NAME)_refpolicy.awk $(POLICY_NAME).te > $@
else
BUILD_TE = $(POLICY_NAME).te
endif

# 系統が前回のビルドと変わった時だけ、系統の記録ファイルを更新して、.modと.ppを作り直す
# (.teの内容が同じでも、系統によって生成するソースが違うため)
.flavor: FORCE
	@echo "$(EFFECTIVE_FLAVOR)" | cmp -s - $@ || echo "$(EFFECTIVE_FLAVOR)" > $@

FORCE:

$(POLICY_NAME).mod: $(BUILD_TE) .flavor
	@echo "Compiling Type Enforcement policy ($(EFFECTIVE_FLAVOR)): $< -> $@"
	$(CHECKMODULE) -M -m -o $@ $<

# .modと.fcを.ppにまとめる
$(POLICY_NAME).pp: $(POLICY_NAME).mod $(POLICY_NAME).fc
	@echo "Packaging SELinux policy module: $@"
	$(SEMODULE_PACKAGE) -o $@ -m $(POLICY_NAME).mod -f $(POLICY_NAME).fc

########################################
# インストールと管理
########################################

# ラベルの付け直しは、存在するパスだけに行う
# 失敗しても、モジュールの読み込み自体は完了しているため続行する
define relabel
	@if [ -x "$(RESTORECON)" ]; then \
		failed=""; \
		for p in $(RELABEL_PATHS) $(RELABEL_HOME_GLOBS); do \
			if [ -e "$$p" ]; then $(RESTORECON) -R $(1) "$$p" || failed="$$failed $$p"; fi; \
		done; \
		if [ -n "$$failed" ]; then \
			echo "WARNING: module is loaded, but relabeling failed for:$$failed"; \
		fi; \
	else \
		echo "WARNING: restorecon not found, skipping file relabeling"; \
	fi
endef

install: all
	@echo "Installing SELinux policy module: $(POLICY_NAME)"
	@if [ ! -x "$(SEMODULE)" ]; then \
		echo "ERROR: semodule not found at $(SEMODULE)"; \
		exit 1; \
	fi
	$(SEMODULE) -i $(POLICY_NAME).pp
	@echo "Policy module installed successfully"
	@echo "Relabeling Hazkey Community files..."
	$(call relabel,-v)
	@echo ""
	@echo "Restart the conversion server to run it in the new domain:"
	@echo "  pkill -u <user> -f '^([^ ]*/)?hazkey-community-server( |\$$)'"
	@echo "If the server cannot start, delete the old socket and lock file (restorecon does not relabel them):"
	@echo "  rm -f \$$XDG_RUNTIME_DIR/hazkey-community-server.*"
	@echo "Verify: semodule -l | grep $(POLICY_NAME)"

load: install

unload:
	@echo "Removing SELinux policy module: $(POLICY_NAME)"
	@if [ ! -x "$(SEMODULE)" ]; then \
		echo "ERROR: semodule not found at $(SEMODULE)"; \
		exit 1; \
	fi
	$(SEMODULE) -r $(POLICY_NAME) || true
	$(call relabel,)
	@echo "Policy module removed (if it was installed)"

########################################
# ユーティリティ
########################################

# checkmoduleは、モジュール名と出力ファイル名の一致を要求するため、作業用ディレクトリへ出力する
# 他のポリシーモジュールから使う.ifを、系統に合わせて用意する
# redhatの系統では、hazkey_community.ifをそのまま使う
interface:
ifeq ($(EFFECTIVE_FLAVOR),refpolicy)
	@mkdir -p .build
	awk -f $(POLICY_NAME)_refpolicy.awk $(POLICY_NAME).if > .build/$(POLICY_NAME).if
	@echo "Generated .build/$(POLICY_NAME).if (refpolicy)"
else
	@echo "Use $(POLICY_NAME).if as is (redhat)"
endif

check: $(BUILD_TE)
	@echo "Checking policy syntax ($(EFFECTIVE_FLAVOR))..."
	@mkdir -p .check
	$(CHECKMODULE) -M -m -o .check/$(POLICY_NAME).mod $(BUILD_TE)
	@rm -rf .check
	@echo "Syntax check passed"

clean:
	rm -f $(POLICY_NAME).pp $(POLICY_NAME).mod .flavor
	rm -rf .check .build

help:
	@echo "Hazkey Community SELinux Policy Module Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make              - Build policy package ($(POLICY_NAME).pp)"
	@echo "  make install      - Load the module and relabel files (requires root)"
	@echo "  make load         - Alias for 'make install'"
	@echo "  make unload       - Remove the module and relabel files (requires root)"
	@echo "  make check        - Check policy syntax without building"
	@echo "  make interface    - Generate the interface file for the selected flavor (.build/ for refpolicy)"
	@echo "  make clean        - Remove build artifacts"
	@echo ""
	@echo "Options:"
	@echo "  FLAVOR=auto|redhat|refpolicy - Type name flavor (default: auto, detected from the installed policy)"
	@echo "                                 redhat: Fedora / RHEL / openSUSE, refpolicy: Debian / Ubuntu"
