const userList = document.getElementById('userList');
const messageDiv = document.getElementById('message');
const userModal = document.getElementById('userModal');
const userForm = document.getElementById('userForm');
const modalTitle = document.getElementById('modalTitle');
const usernameInput = document.getElementById('usernameInput');
const passwordInput = document.getElementById('passwordInput');
const editModeInput = document.getElementById('editMode');

// Load users on start
loadUsers();

async function loadUsers() {
    try {
        const res = await fetch('/api/users');
        if (!res.ok) throw new Error('Failed to load users');
        const users = await res.json();
        renderUsers(users);
    } catch (err) {
        showMessage(err.message, 'error');
    }
}

function renderUsers(users) {
    userList.innerHTML = '';
    users.forEach(user => {
        const li = document.createElement('li');
        li.className = 'user-item';
        li.innerHTML = `
            <span>${user.username}</span>
            <div class="user-actions">
                <button class="btn-small btn-edit" onclick="openChangePasswordModal('${user.username}')">Change Password</button>
                <button class="btn-small btn-delete" onclick="deleteUser('${user.username}')">Delete</button>
            </div>
        `;
        userList.appendChild(li);
    });
}

// Modal functions
function openAddUserModal() {
    modalTitle.textContent = 'Add User';
    usernameInput.value = '';
    usernameInput.disabled = false;
    passwordInput.value = '';
    passwordInput.placeholder = 'Required';
    passwordInput.required = true;
    editModeInput.value = 'false';
    userModal.style.display = 'flex';
}

// Reusing the modal logic effectively for "Change Password" by creating a dedicated mode or reusing the form
// Here "Change Password" is basically "Edit User" but we only allow changing password.
function openChangePasswordModal(username) {
    modalTitle.textContent = `Change Password for ${username}`;
    usernameInput.value = username;
    usernameInput.disabled = true; // Cannot change username
    passwordInput.value = '';
    passwordInput.placeholder = 'New Password';
    passwordInput.required = true;
    editModeInput.value = 'true';
    userModal.style.display = 'flex';
}

function closeUserModal() {
    userModal.style.display = 'none';
}

window.onclick = function (event) {
    if (event.target === userModal) {
        closeUserModal();
    }
}

// Form Submit
userForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const username = usernameInput.value;
    const password = passwordInput.value;
    const isEdit = editModeInput.value === 'true';

    try {
        let res;
        if (isEdit) {
            // Change Password
            res = await fetch(`/api/users/${username}/password`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ username, password })
            });
        } else {
            // Create User
            res = await fetch('/api/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ username, password })
            });
        }

        if (res.ok) {
            showMessage(isEdit ? 'Password updated' : 'User created', 'success');
            closeUserModal();
            loadUsers();
        } else {
            const text = await res.text();
            throw new Error(text);
        }
    } catch (err) {
        alert(err.message);
    }
});

async function deleteUser(username) {
    if (!confirm(`Are you sure you want to delete user "${username}"?`)) return;

    try {
        const res = await fetch(`/api/users/${username}`, {
            method: 'DELETE'
        });

        if (res.ok) {
            showMessage('User deleted', 'success');
            loadUsers();
        } else {
            const text = await res.text();
            throw new Error(text);
        }
    } catch (err) {
        alert(err.message);
    }
}

function showMessage(msg, type) {
    // Simple alert or toast, for now just console or alert if critical
    // Could enhance UI later
    console.log(`[${type}] ${msg}`);
}
