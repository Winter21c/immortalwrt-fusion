'use strict';
'require baseclass';
'require ui';

return baseclass.extend({
	menuIcons: {
		'fwx_network': 'fwx_network',
		'fwx_wireless': 'fwx_wireless',
		'fwx_parental_control': 'fwx_parental_control',
		'fwx_advance': 'fwx_advance',
		'fwx_dashboard': 'fwx_dashboard',
		'fwx_internet_record': 'fwx_internet_record',
		'fwx_user': 'fwx_user',
		'fwx_monitor': 'fwx_monitor',
		'fwx_app_center': 'fwx_app_center',
		'fwx_tools': 'fwx_tools',
		'fwx_games': 'fwx_games',
		'fwx_cloud_service': 'fwx_cloud_service',
		'fwx_ac': 'fwx_ac'
	},
	defaultIcon: 'default',
	__init__() {
		ui.menu.load().then(L.bind(this.render, this));
	},

	render(tree) {
		this.renderModeMenu(tree);
		this.renderCategoryNav();
		this.renderBreadcrumb(tree);
		this.setup_mobile_menu();
		this.setup_content_scrollbar();
		const category = L.env.dispatchpath[1]
			? (this.getMenuCategory(L.env.dispatchpath[1]) === 'menu-item-basic' ? 'basic' : 'advanced')
			: localStorage.getItem('luci-menu-category') || 'basic';
		this.switchCategory(category);

		let node = tree;
		let url = '';
		for (let i = 0; i < 3 && node && L.env.dispatchpath.length >= 3; i++) {
			node = node.children && node.children[L.env.dispatchpath[i]];
			url += (url ? '/' : '') + L.env.dispatchpath[i];
		}
		if (node && L.env.dispatchpath.length >= 3)
			this.renderTabMenu(node, url, 0);
	},

	setup_content_scrollbar() {
		const content = document.getElementById('maincontent');
		if (!content)
			return;
		let hide_timer;
		const show_scrollbar = () => {
			content.classList.add('scrollbar_active');
			clearTimeout(hide_timer);
			hide_timer = setTimeout(() => content.classList.remove('scrollbar_active'), 1000);
		};
		content.addEventListener('scroll', show_scrollbar, { passive: true });
		content.addEventListener('wheel', show_scrollbar, { passive: true });
	},

	setup_mobile_menu() {
		const toggle = document.querySelector('.mobile-menu-toggle');
		const sidebar = document.querySelector('.sidebar-nav');
		const media_query = window.matchMedia('(max-width: 768px)');
		const set_open = (open) => {
			sidebar.classList.toggle('mobile-open', open);
			toggle.setAttribute('aria-expanded', String(open));
		};
		toggle.addEventListener('click', () => set_open(!sidebar.classList.contains('mobile-open')));
		document.addEventListener('click', (event) => {
			if (!sidebar.contains(event.target) && !toggle.contains(event.target))
				set_open(false);
		});
		document.addEventListener('keydown', (event) => {
			if (event.key === 'Escape' && sidebar.classList.contains('mobile-open')) {
				set_open(false);
				toggle.focus();
			}
		});
		media_query.addEventListener('change', () => set_open(false));
	},

	renderCategoryNav() {
		const savedCategory = localStorage.getItem('luci-menu-category') || 'basic';
		
		const titleText = (
			(L && L.env && L.env.hostname) ||
			(document.querySelector('header a.brand') && document.querySelector('header a.brand').textContent || '').trim() ||
			'FanchmWrt'
		);
		const brandElement = E('a', { 'class': 'top-navbar-brand', 'href': L.url('admin', 'fwx_dashboard') }, [
			E('span', { 'class': 'top-navbar-title' }, [titleText])
		]);
		brandElement.addEventListener('click', function() {
			localStorage.setItem('luci-menu-category', 'basic');
		});
		document.querySelector('.sidebar_brand').addEventListener('click', function() {
			localStorage.setItem('luci-menu-category', 'basic');
		});
		
		const createModeItem = (category, title, href) => {
			const item = E('li', {
				'class': 'mode-item' + (savedCategory === category ? ' active' : ''),
				'data-category': category
			}, [
				E('a', { 'href': href }, [
					E('span', { 'class': 'mode-check', 'aria-hidden': 'true' }),
					E('span', { 'class': 'mode-title' }, [_(title)])
				])
			]);

			item.querySelector('a').addEventListener('click', function() {
				localStorage.setItem('luci-menu-category', category);
			});

			return item;
		};

		const modeMenu = E('div', { 'class': 'top-user-menu top-mode-menu' }, [
			E('button', {
				'class': 'top-user-button top-more-button',
				'type': 'button',
				'aria-label': _('Mode menu')
			}, [
				E('span', { 'class': 'mode_button_label' }, [savedCategory === 'advanced' ? _('Advanced Mode') : _('Normal Mode')]),
				E('span', { 'class': 'top-more-icon' }, ['⋮'])
			]),
			E('ul', { 'class': 'top-user-dropdown top-mode-dropdown' }, [
				createModeItem('basic', 'Normal Mode', L.url('admin', 'fwx_dashboard')),
				createModeItem('advanced', 'Advanced Mode', L.url('admin', 'status', 'overview'))
			])
		]);

		const userMenu = E('div', { 'class': 'top-user-menu top-profile-menu' }, [
			E('button', {
				'class': 'top-user-button',
				'type': 'button',
				'aria-label': _('User menu')
			}, [
				E('span', { 'class': 'top-user-icon', 'aria-hidden': 'true' })
			]),
			E('ul', { 'class': 'top-user-dropdown top-profile-dropdown' }, [
				E('li', { 'class': 'system-item' }, [
					E('a', { 'href': L.url('admin', 'system', 'reboot') }, [_('Device Reboot')])
				]),
				E('li', { 'class': 'system-item' }, [
					E('a', { 'href': L.url('admin', 'system', 'flash') }, [_('System Upgrade')])
				]),
				E('li', { 'class': 'system-item' }, [
					E('a', { 'href': L.url('admin', 'system', 'admin') }, [_('Change Password')])
				]),
				E('li', { 'class': 'logout-item' }, [
					E('a', { 'href': '#' }, [_('Logout')])
				])
			])
		]);

		const closeTopMenus = () => {
			userMenu.classList.remove('open');
			modeMenu.classList.remove('open');
		};

		const userBtn = userMenu.querySelector('.top-user-button');
		userBtn.addEventListener('click', function(ev) {
			ev.preventDefault();
			ev.stopPropagation();
			const shouldOpen = !userMenu.classList.contains('open');
			closeTopMenus();
			if (shouldOpen) {
				userMenu.classList.add('open');
			}
		});

		const modeBtn = modeMenu.querySelector('.top-more-button');
		modeBtn.addEventListener('click', function(ev) {
			ev.preventDefault();
			ev.stopPropagation();
			const shouldOpen = !modeMenu.classList.contains('open');
			closeTopMenus();
			if (shouldOpen) {
				modeMenu.classList.add('open');
			}
		});

		userMenu.querySelectorAll('.system-item a').forEach((link) => {
			link.addEventListener('click', function() {
				localStorage.setItem('luci-menu-category', 'advanced');
				closeTopMenus();
			});
		});

		const logoutLink = userMenu.querySelector('.logout-item a');
		logoutLink.addEventListener('click', function(ev) {
			ev.preventDefault();
			ev.stopPropagation();
			closeTopMenus();
			window.dispatchEvent(new CustomEvent('logout', {
				detail: { source: 'top-profile-menu' }
			}));
			window.location.href = L.url('admin', 'logout');
		});

		document.addEventListener('click', function(ev) {
			if (!userMenu.contains(ev.target) && !modeMenu.contains(ev.target)) {
				closeTopMenus();
			}
		});

		document.addEventListener('keydown', function(ev) {
			if (ev.key === 'Escape') {
				closeTopMenus();
			}
		});

		const topNavbarContent = E('div', { 'class': 'top-navbar-content' }, [
			E('button', {
				'class': 'mobile-menu-toggle', 'type': 'button',
				'aria-label': _('Menu'), 'aria-controls': 'theme-sidebar',
				'aria-expanded': 'false'
			}, ['☰']),
			brandElement,
			E('div', { 'class': 'top_navbar_context' }, [document.title]),
			E('div', { 'class': 'top-navbar-right' }, [userMenu, modeMenu])
		]);
		const topNavbar = E('div', { 'class': 'top-navbar' }, [topNavbarContent]);

		const existing_navbar = document.querySelector('.top-navbar');
		if (existing_navbar)
			existing_navbar.remove();
		document.body.insertBefore(topNavbar, document.body.firstChild);
	},
	

	renderBreadcrumb(tree) {
		if (!L.env.dispatchpath || L.env.dispatchpath.length === 0) {
			return;
		}

		const breadcrumbItems = [];
		let currentNode = tree;
		let currentPath = '';

		for (let i = 0; i < L.env.dispatchpath.length && currentNode; i++) {
			const pathSegment = L.env.dispatchpath[i];
			currentPath += (currentPath ? '/' : '') + pathSegment;
			
			if (currentNode.children && currentNode.children[pathSegment]) {
				currentNode = currentNode.children[pathSegment];
				
				if (i === 0 && pathSegment === 'admin') {
					const homeItem = E('li', { 'class': 'home-item' }, [
						E('a', { 'href': L.url('admin', 'fwx_dashboard'), 'title': _('Home'), 'aria-label': _('Home') }, [
							E('span', { 'class': 'home-icon', 'aria-hidden': 'true' }, ['🏠'])
						])
					]);
					breadcrumbItems.push(homeItem);
				} else {
					const breadcrumbItem = E('li', {}, [
						E('span', {}, [_(currentNode.title)])
					]);
					
					breadcrumbItems.push(breadcrumbItem);
				}
			}
		}

		if (breadcrumbItems.length === 0) {
			return;
		}

		const breadcrumbContainer = E('div', { 'class': 'breadcrumb-container' }, [
			E('ol', { 'class': 'breadcrumb' }, breadcrumbItems)
		]);
		const navbar_context = document.querySelector('.top_navbar_context');
		if (navbar_context) {
			const navbar_breadcrumb = breadcrumbContainer.firstElementChild.cloneNode(true);
			navbar_breadcrumb.lastElementChild.setAttribute('aria-current', 'page');
			navbar_context.replaceChildren(navbar_breadcrumb);
		}

		const mainContent = document.querySelector('#maincontent') || document.querySelector('.main');
		if (mainContent) {
			const existingBreadcrumb = mainContent.querySelector('.breadcrumb-container');
			if (existingBreadcrumb) {
				existingBreadcrumb.remove();
			}
			
			mainContent.insertBefore(breadcrumbContainer, mainContent.firstChild);
		}
	},

	switchCategory(category) {
		const mode_label = document.querySelector('.mode_button_label');
		if (mode_label)
			mode_label.textContent = category === 'advanced' ? _('Advanced Mode') : _('Normal Mode');
		document.querySelectorAll('.top-user-dropdown .mode-item').forEach((item) => {
			item.classList.toggle('active', item.getAttribute('data-category') === category);
		});
		document.querySelectorAll('#topmenu > li').forEach((item) => {
			item.hidden = !item.classList.contains('menu-item-' + category);
		});
		localStorage.setItem('luci-menu-category', category);
	},

	getMenuCategory(menuName) {
		const normalizedName = (menuName || '').toLowerCase();
		if (normalizedName.startsWith('fwx')) {
			return 'menu-item-basic';
		}
		return 'menu-item-advanced';
	},

	renderTabMenu(tree, url, level) {
		level = level || 0;
		
		const container = document.querySelector('#tabmenu');
		const ul = E('ul', { 'class': 'tabs' });
		const children = ui.menu.getChildren(tree);
		let activeNode = null;

		children.forEach(child => {
			const isActive = (L.env.dispatchpath[3 + level] == child.name);
			const activeClass = isActive ? ' active' : '';
			const className = 'tabmenu-item-%s %s'.format(child.name, activeClass);

			ul.appendChild(E('li', { 'class': className }, [
				E('a', { 'href': L.url(url, child.name) }, [ _(child.title) ] )]));

			if (isActive)
				activeNode = child;
		});

		if (ul.children.length == 0)
			return E([]);

		container.appendChild(ul);
		container.style.display = '';

		if (activeNode)
			this.renderTabMenu(activeNode, url + '/' + activeNode.name, level + 1);

		return ul;
	},

	renderMainMenu(tree, url, level) {
		level = level || 0;
		const ul = level === 0 ? document.querySelector('#topmenu') : E('ul', { 'class': 'dropdown-menu' });
		if (level > 1)
			return ul;
		ui.menu.getChildren(tree).forEach((child) => {
			const submenu = this.renderMainMenu(child, url + '/' + child.name, level + 1);
			const has_submenu = level === 0 && submenu.children.length > 0;
			const is_active = L.env.dispatchpath[level + 1] === child.name && L.env.dispatchpath[level] === tree.name;
			const classes = level === 0 ? [this.getMenuCategory(child.name)] : [];
			if (has_submenu) classes.push('dropdown');
			if (is_active) {
				classes.push(has_submenu ? 'current_group' : 'active');
				if (has_submenu) classes.push('open');
			}
			const link = E('a', {
				'class': (has_submenu ? 'menu ' : '') + (level === 0 ? 'menu-icon-' + (this.menuIcons[child.name] || this.defaultIcon) : ''),
				'href': has_submenu ? '#' : L.url(url, child.name)
			}, [_(child.title)]);
			const li = E('li', { 'class': classes.join(' ') }, has_submenu ? [link, submenu] : [link]);
			if (has_submenu) {
				link.setAttribute('aria-expanded', String(is_active));
				link.addEventListener('click', (event) => {
					event.preventDefault();
					const open = !li.classList.contains('open');
					ul.querySelectorAll(':scope > .dropdown.open').forEach((item) => {
						item.classList.remove('open');
						item.querySelector('a.menu').setAttribute('aria-expanded', 'false');
					});
					li.classList.toggle('open', open);
					link.setAttribute('aria-expanded', String(open));
				});
			} else if (is_active) {
				link.setAttribute('aria-current', 'page');
			}
			ul.appendChild(li);
		});
		if (level === 0) ul.style.display = '';
		return ul;
	},

	renderModeMenu(tree) {
		const ul = document.querySelector('#modemenu');
		const menu = document.querySelector('#topmenu');
		ul.replaceChildren();
		menu.replaceChildren();
		ui.menu.getChildren(tree).forEach((child, index) => {
			const is_active = L.env.requestpath.length ? child.name === L.env.requestpath[0] : index === 0;
			ul.appendChild(E('li', { 'class': is_active ? 'active' : '' }, [
				E('a', { 'href': L.url(child.name) }, [_(child.title)])
			]));
			if (is_active) this.renderMainMenu(child, child.name);
		});
		ul.style.display = ul.children.length > 1 ? '' : 'none';
	}
});
