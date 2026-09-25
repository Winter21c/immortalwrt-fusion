'use strict';
'require ui';
'require view';

return view.extend({
	render: function() {
		var form = document.querySelector('form'),
		    btn = document.querySelector('button');

		document.body.classList.add('login_page');

		var dlg = ui.showModal(
			'FanchmWrt',
			[].slice.call(document.querySelectorAll('section > *')),
			'login'
		);

		form.addEventListener('keypress', function(ev) {
			if (ev.key == 'Enter')
				btn.click();
		});

		btn.addEventListener('click', function() {
			dlg.querySelectorAll('*').forEach(function(node) { node.style.display = 'none' });
			dlg.appendChild(E('div', { 'class': 'spinning' }, _('Logging in…')));

			form.submit()
		});

		return '';
	},

	addFooter: function() {}
});
