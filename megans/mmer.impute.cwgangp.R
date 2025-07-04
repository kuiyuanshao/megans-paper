pacman::p_load(progress, torch)

cwgangp_default <- function(batch_size = 500, gamma = 1, lambda = 10, 
                            alpha = 0, beta = 1, at_least_p = 1/2, 
                            lr_g = 2e-4, lr_d = 2e-4, g_betas = c(0.5, 0.9), d_betas = c(0.5, 0.9), 
                            g_weight_decay = 1e-7, d_weight_decay = 1e-7, 
                            g_dim = 256, d_dim = 256, pac = 10, 
                            n_g_layers = 3, n_d_layers = 3, discriminator_steps = 1,
                            tau = 0.2, hard = F, token_dim = 8, 
                            type_g = "mlp", type_d = "mlp"){
  
  list(
    batch_size = batch_size, gamma = gamma, lambda = lambda, alpha = alpha, beta = beta, 
    at_least_p = at_least_p, lr_g = lr_g, lr_d = lr_d, g_betas = g_betas, d_betas = d_betas, 
    g_weight_decay = g_weight_decay, d_weight_decay = d_weight_decay, 
    g_dim = g_dim, d_dim = d_dim, pac = pac, n_g_layers = n_g_layers, n_d_layers = n_d_layers, 
    discriminator_steps = discriminator_steps, tau = tau, hard = hard, token_dim = token_dim,
    type_g = type_g, type_d = type_d
  )
}

mmer.impute.cwgangp <- function(data, m = 5, 
                                num.normalizing = "mode", 
                                cat.encoding = "onehot", 
                                device = "cpu",
                                epochs = 2500, 
                                params = list(), data_info = list(),
                                AIPW = F,
                                save.model = FALSE, save.step = 500){
  params <- do.call("cwgangp_default", params)
  device <- torch_device(device)
  list2env(params, envir = environment())
  list2env(data_info, envir = environment())
  
  # phase2_vars <- names(data)[which(sapply(data, function(x) any(is.na(x))))]
  # phase1_vars <- names(data)[which(!(names(data) %in% phase2_vars))]
  conditions_vars <- names(data)[which(!(names(data) %in% phase2_vars))]
  phase1_rows <- which(is.na(data[, phase2_vars[1]]))
  phase2_rows <- which(!is.na(data[, phase2_vars[1]]))
  normalize <- paste("normalize", num.normalizing, sep = ".")
  encode <- paste("encode", cat.encoding, sep = ".")
  
  weights <- as.numeric(as.character(data[, names(data) %in% weight_var]))
  weights_t <- torch_tensor(as.matrix(weights), device = device)
  
  if (type_g == "mmer"){
    data[, match((phase2_vars[phase2_vars %in% num_vars]), names(data))] <- 
      data[, match((phase1_vars[phase1_vars %in% num_vars]), names(data))] - 
      data[, match((phase2_vars[phase2_vars %in% num_vars]), names(data))]
  }
  
  data_norm <- do.call(normalize, args = list(
    data = data,
    num_vars = num_vars, 
    phase1_vars, phase2_vars
  ))
  
  if (num.normalizing == "mode"){
    mode_cat_vars <- c(cat_vars, setdiff(names(data_norm$data), names(data)))
    phase1_vars <- c(phase1_vars, names(data_norm$data)[
      !names(data_norm$data) %in% names(data) &
        names(data_norm$data) %in% paste0(phase1_vars, sep = "_mode")])
    phase2_vars <- c(phase2_vars, names(data_norm$data)[
      !names(data_norm$data) %in% names(data) &
        names(data_norm$data) %in% paste0(phase2_vars, sep = "_mode")])
    conditions_vars <- c(conditions_vars, names(data_norm$data)[
      !names(data_norm$data) %in% names(data) &
        names(data_norm$data) %in% paste0(conditions_vars, sep = "_mode")])
  }
  
  data_encode <- do.call(encode, args = list(
    data = data_norm$data,
    cat_vars = mode_cat_vars, 
    conditions_vars, type_g
  ))
  nrows <- nrow(data_encode$data)
  ncols <- ncol(data_encode$data)
  #Prepare training tensors
  data_training <- data_encode$data
  
  
  phase1_vars_encode <- c(phase1_vars[!phase1_vars %in% mode_cat_vars], 
                          unlist(data_encode$new_col_names[phase1_vars]))
  phase2_vars_encode <- c(phase2_vars[!phase2_vars %in% mode_cat_vars], 
                          unlist(data_encode$new_col_names[phase2_vars]))
  conditions_vars_encode <- c(conditions_vars[!conditions_vars %in% mode_cat_vars], 
                              unlist(data_encode$new_col_names[conditions_vars]))
  
  num_inds <- which(phase2_vars_encode %in% num_vars) # all numeric inds
  cat_inds <- which(phase2_vars_encode %in% unlist(data_encode$new_col_names)) # all one hot inds, involving modes
  new_order <- c(phase2_vars_encode[num_inds], phase2_vars_encode[cat_inds],
                 setdiff(names(data_training), phase2_vars_encode))
  data_training <- data_training[, new_order]
  binary_indices_reordered <- lapply(data_encode$binary_indices, function(indices) {
    match(names(data_encode$data)[indices], names(data_training))
  })
  data_encode$binary_indices <- binary_indices_reordered
  
  data_mask <- torch_tensor(1 - is.na(data_training), device = device)
  conditions_t <- torch_tensor(as.matrix(data_training[, !names(data_training) %in% phase2_vars_encode]), device = device)
  phase2_t <- data_training[, names(data_training) %in% phase2_vars_encode, drop = F]
  phase2_t[is.na(phase2_t)] <- 0 
  phase2_t <- torch_tensor(as.matrix(phase2_t), device = device)
  
  if (type_g == "mmer"){
    phase1_cats <- unlist(data_encode$new_col_names[cat_vars[cat_vars %in% phase1_vars]])
    phase2_cats <- unlist(data_encode$new_col_names[cat_vars[cat_vars %in% phase2_vars]])
    ind1 <- match(phase1_cats, names(data_training))
    ind2 <- match(phase2_cats, names(data_training))
    confusmat <- lapply(1:length(ind1), function(i) prop.table(table(data_training[, ind2[i]], 
                                                                     data_training[, ind1[i]]), 1))
    CM_tensors <- lapply(confusmat, function(cm) torch_tensor(cm, dtype = torch_float()))
    
    phase1_t_cat <- data_training[, match(phase1_cats, names(data_training))]
    phase1_t_cat <- torch_tensor(as.matrix(phase1_t_cat), device = device)
    phase2_cats_inds <- match(phase2_cats, names(data_training)) # only true cat inds
    # for categorical variables, NN outputs real categories, 
    # then times by CM_list to trasnform it to phase1 categories, and then calculate the CE
  }

  if (cat.encoding == "token"){
    cat_inds_p1 <- (unlist(binary_indices_reordered) - 
                      length(phase2_vars))[(unlist(binary_indices_reordered) - length(phase2_vars)) > 0]
    num_inds_p1 <- which(!(1:(ncols - length(phase2_vars)) %in% cat_inds_p1))
    tokenizer <- Tokenizer(dim(phase1_t)[2], cat_inds_p1, 
                           params$token_dim, unlist(data_encode$n_unique))
    ncols <- params$token_dim * (dim(phase1_t)[2] + 1) + length(phase2_vars)
  }else{
    ncols <- ncols
  }
  tensor_list <- list(data_mask, conditions_t, phase2_t, phase1_t_cat, weights_t)
  
  #mnet <- m_net(dim(conditions_t)[2], params)
  gnet <- do.call(paste("generator", type_g, sep = "."), 
                  args = list(n_g_layers, params, 
                              ncols, length(phase2_vars_encode),
                              num_inds, cat_inds))$to(device = device)
  dnet <- do.call(paste("discriminator", type_d, sep = "."), 
                  args = list(n_d_layers, params, ncols))$to(device = device)
  
  #m_solver <- torch::optim_adam(mnet$parameters, lr = lr_d)
  g_solver <- torch::optim_adam(gnet$parameters, lr = lr_g, 
                                betas = g_betas, weight_decay = g_weight_decay)
  d_solver <- torch::optim_adam(dnet$parameters, lr = lr_d, 
                                betas = d_betas, weight_decay = d_weight_decay)
  
  training_loss <- matrix(0, nrow = epochs, ncol = 2)
  pb <- progress_bar$new(
    format = paste0("Running :what [:bar] :percent eta: :eta | G Loss: :g_loss | D Loss: :d_loss"),
    clear = FALSE, total = epochs, width = 100)
  
  if (save.step > 0){
    step_result <- list()
    p <- 1
  }
  
  d_output <- matrix(0, nrow = epochs, ncol = 4)
  for (i in 1:epochs){
    for (d in 1:discriminator_steps){
      batch <- samplebatches(data, data_training, tensor_list, 
                             phase1_rows, phase2_rows, phase2_vars_encode,
                             data_encode$new_col_names, batch_size, at_least_p = 0.5, 
                             weights)
      
      #W <- batch[[6]] 
      X_star_cat <- batch[[4]]
      X <- batch[[3]]
      C <- batch[[2]]
      M <- batch[[1]]
      I <- M[, 1] == 1
      #W <- W * I$unsqueeze(2)
      
      fakez <- torch_normal(mean = 0, std = 1, size = c(X$size(1), g_dim))$to(device = device)
      
      if (cat.encoding == "token"){
        C <- tokenizer(C[, num_inds_p1, drop = F], 
                       C[, cat_inds_p1, drop = F])
        C <- C$reshape(c(C$size(1), C$size(2) * C$size(3)))
        fakez_C <- torch_cat(list(fakez, C), dim = 2)
      }else{
        fakez_C <- torch_cat(list(fakez, C), dim = 2)
      }
      
      fake <- gnet(fakez_C)
      fake <- activation_fun(fake, data_encode, phase2_vars_encode, 
                             tau = tau, hard = hard)
    
      fake_C_I <- torch_cat(list(fake[I, , drop = F], C[I, , drop = F]), dim = 2)
      true_C_I <- torch_cat(list(X[I, , drop = F], C[I, , drop = F]), dim = 2)
      
      y_fake_I <- dnet(fake_C_I)
      y_true_I <- dnet(true_C_I)
      
      d_output[i, ] <- c(as.numeric(y_fake_I$mean()), 
                         as.numeric(y_true_I$mean()), 
                         as.numeric(y_fake_I$std()), 
                         as.numeric(y_true_I$std()))
      
      gp <- gradient_penalty(dnet, true_C_I, fake_C_I, pac = params$pac, device = device)
      # if (AIPW){
      #   # NI for Phase-1 unselected samples
      #   fake_C_NI <- torch_cat(list(fake[I$logical_not(), , drop = F], 
      #                               C[I$logical_not(), , drop = F]), dim = 2)
      #   
      #   y_true_pred <- mnet(C[I, ])
      #   y_true_mI <- dnet(true_C_I)
      #   m_loss <- nnf_mse_loss(y_true_pred, y_true_mI)
      #   m_solver$zero_grad()
      #   m_loss$backward()
      #   m_solver$step()
      #   
      #   # Critic Scores for Phase-1
      #   y_fake_NI <- dnet(fake_C_NI)
      #   
      #   y_pred_I <- mnet(C[I, , drop = F])$detach()
      #   y_pred_NI <- mnet(C[I$logical_not(), , drop = F])$detach()
      #   y_pred <- torch_cat(list(y_pred_I, y_pred_NI), dim = 1)
      #   
      #   W_pack <- (W[I])$reshape(c(-1, params$pac))$mean(dim = 2)
      #   revW_pack <- (1 - W[I])$reshape(c(-1, params$pac))$mean(dim = 2)
      #   revW_pack <- torch_cat(list((1 - W[I])$reshape(c(-1, params$pac))$mean(dim = 2),
      #                               (1 - W[I$logical_not()])$reshape(c(-1, params$pac))$mean(dim = 2)),
      #                          dim = 1)
      #   d_loss <- -torch_mean(W_pack$unsqueeze(2) * (y_true_I - y_fake_I)) + 
      #     torch_mean(revW_pack$unsqueeze(2) * (y_pred)) + 
      #     params$lambda * gp
      # }else{
        d_loss <- -(torch_mean(y_true_I) - torch_mean(y_fake_I)) + 
          params$lambda * gp
      # }
      
      d_solver$zero_grad()
      d_loss$backward()
      d_solver$step()
    }
    batch <- samplebatches(data, data_training, tensor_list, 
                           phase1_rows, phase2_rows, phase2_vars_encode,
                           data_encode$new_col_names, batch_size, at_least_p = 0.5, 
                           weights)
    X <- batch[[3]]
    C <- batch[[2]]
    M <- batch[[1]]
    I <- M[, 1] == 1
    
    fakez <- torch_normal(mean = 0, std = 1, size = c(X$size(1), g_dim))$to(device = device)
    if (cat.encoding == "token"){
      C <- tokenizer(C[, num_inds_p1, drop = F], 
                     C[, cat_inds_p1, drop = F])
      C <- C$reshape(c(C$size(1), C$size(2) * C$size(3)))
      fakez_C <- torch_cat(list(fakez, C), dim = 2)
    }else{
      fakez_C <- torch_cat(list(fakez, C), dim = 2)
    }
    fake <- gnet(fakez_C)
    fake <- activation_fun(fake, data_encode, phase2_vars_encode, 
                           tau = tau, hard = hard)
    if (type_g == "mmer"){
      X_star_cat <- batch[[4]]
      notI <- I$logical_not()
      for (k in 1:length(phase2_cats_inds)){
        p_act <- fake[notI, phase2_cats_inds[k]]
        cm <- CM_tensors[[k]]
        fake[notI, phase2_cats_inds[k]] <- (1 - p_act) * cm[1, 2] + p_act * cm[2, 2]
        X[notI, phase2_cats_inds[k]] <- X_star_cat[notI, k]
      }
    }
    fake_C <- torch_cat(list(fake, C), dim = 2)
    
    y_fake <- dnet(fake_C)
    g_loss <- g_loss(y_fake, fake, X, data_encode, 
                     phase2_vars_encode, params, num_inds, cat_inds)
    
    g_solver$zero_grad()
    g_loss$backward()
    g_solver$step()
    
    training_loss[i, ] <- c(g_loss$item(), d_loss$item())
    pb$tick(tokens = list(
      what = "cWGAN-GP",
      g_loss = sprintf("%.4f", g_loss$item()),
      d_loss = sprintf("%.4f", d_loss$item())
    ))
    Sys.sleep(1 / 10000)
    
    if (save.step > 0){
      if (i %% save.step == 0){
        if (cat.encoding == "token"){
          tokenizer_list <- list(tokenizer = tokenizer, 
                                 cat_inds_p1 = cat_inds_p1, num_inds_p1 = num_inds_p1)
        }else{
          tokenizer_list <- NULL
        }
        result <- generateImpute(gnet, m = 1, 
                                 data, data_norm, 
                                 data_encode, data_training,
                                 phase1_vars_encode, phase2_vars_encode, 
                                 num_vars, num.normalizing, cat.encoding, 
                                 batch_size, g_dim, device, params, tensor_list, 
                                 tokenizer_list)
        step_result[[p]] <- result$gsample
        p <- p + 1
      }
    }
  }
  training_loss <- data.frame(training_loss)
  names(training_loss) <- c("G Loss", "D Loss")
  if (cat.encoding == "token"){
    tokenizer_list <- list(tokenizer = tokenizer, cat_inds_p1 = cat_inds_p1, num_inds_p1 = num_inds_p1)
  }else{
    tokenizer_list <- NULL
  }
  gnet$eval()
  result <- generateImpute(gnet, m = m, 
                           data, data_norm, 
                           data_encode, data_training,
                           phase1_vars_encode, phase2_vars_encode, num_vars, 
                           num.normalizing, cat.encoding, 
                           batch_size, g_dim, device, params, tensor_list, 
                           tokenizer_list)
  if (save.model){
    current_time <- Sys.time()
    formatted_time <- format(current_time, "%d-%m-%Y.%S-%M-%H")
    save(gnet, dnet, params, data, data_norm, 
         data_encode, data_training, data_mask,
         phase1_vars, phase2_vars, num.normalizing, cat.encoding, 
         batch_size, g_dim, device, phase1_t, phase2_t, 
         file = paste0("mmer.impute.cwgangp_", formatted_time, ".RData"))
  }
  
  return (list(imputation = result$imputation, 
               gsample = result$gsample, 
               loss = training_loss,
               step_result = step_result,
               d_out = d_output))
}
